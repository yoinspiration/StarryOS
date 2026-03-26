use alloc::sync::Arc;
use core::ops::Deref;
use core::sync::atomic::{AtomicIsize, AtomicU8, Ordering};

use linked_list_r4l::{GetLinks, Links, List};

use crate::BaseScheduler;

const NUM_CLASSES: usize = 3;
const VRUNTIME_SCALE: u128 = 1024;
const DEFAULT_WEIGHTS: [u64; NUM_CLASSES] = [8, 4, 1];

/// Scheduling latency target in ticks.
const SCHED_PERIOD_TICKS: u128 = 15;
/// Minimum timeslice for a class in ticks.
const MIN_SLICE_TICKS: u128 = 2;

pub const CLASS_INTERACTIVE: u8 = 0;
pub const CLASS_NORMAL: u8 = 1;
pub const CLASS_BACKGROUND: u8 = 2;

fn nice_to_class(nice: isize) -> u8 {
    if nice < 0 {
        CLASS_INTERACTIVE
    } else if nice <= 10 {
        CLASS_NORMAL
    } else {
        CLASS_BACKGROUND
    }
}

/// A task wrapper for the [`EevdfClassScheduler`].
///
/// Each task belongs to a scheduling class and has a per-task time slice
/// for round-robin scheduling within its class.
pub struct EevdfTask<T, const MAX_TIME_SLICE: usize> {
    inner: T,
    class_id: AtomicU8,
    time_slice: AtomicIsize,
    links: Links<Self>,
}

impl<T, const S: usize> EevdfTask<T, S> {
    pub const fn new(inner: T) -> Self {
        Self {
            inner,
            class_id: AtomicU8::new(CLASS_NORMAL),
            time_slice: AtomicIsize::new(S as isize),
            links: Links::new(),
        }
    }

    pub fn class_id(&self) -> u8 {
        self.class_id.load(Ordering::Acquire)
    }

    pub fn set_class_id(&self, id: u8) {
        self.class_id.store(id, Ordering::Release);
    }

    fn time_slice(&self) -> isize {
        self.time_slice.load(Ordering::Acquire)
    }

    fn reset_time_slice(&self) {
        self.time_slice.store(S as isize, Ordering::Release);
    }

    pub const fn inner(&self) -> &T {
        &self.inner
    }
}

impl<T, const S: usize> Deref for EevdfTask<T, S> {
    type Target = T;
    #[inline]
    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl<T, const S: usize> GetLinks for EevdfTask<T, S> {
    type EntryType = Self;
    fn get_links(data: &Self::EntryType) -> &Links<Self::EntryType> {
        &data.links
    }
}

struct ClassQueue<T, const S: usize> {
    weight: u64,
    vruntime: u128,
    queue: List<Arc<EevdfTask<T, S>>>,
    nr_running: usize,
}

impl<T, const S: usize> ClassQueue<T, S> {
    const fn new(weight: u64) -> Self {
        Self {
            weight,
            vruntime: 0,
            queue: List::new(),
            nr_running: 0,
        }
    }
}

/// Two-level EEVDF-inspired scheduler.
///
/// Level 1 (class selection): picks the class with the lowest virtual deadline
/// `deadline_i = vruntime_i + request * SCALE / weight_i`, where
/// `request = max(SCHED_PERIOD / nr_runnable_classes, MIN_SLICE)`.
///
/// Level 2 (task selection): round-robin within each class with per-task
/// time slices identical to [`crate::RRScheduler`].
///
/// Default classes: Interactive (weight 8), Normal (weight 4), Background (weight 1).
pub struct EevdfClassScheduler<T, const MAX_TIME_SLICE: usize> {
    classes: [ClassQueue<T, MAX_TIME_SLICE>; NUM_CLASSES],
    min_vruntime: u128,
    current_class: Option<usize>,
}

impl<T, const S: usize> EevdfClassScheduler<T, S> {
    pub const fn new() -> Self {
        Self {
            classes: [
                ClassQueue::new(DEFAULT_WEIGHTS[0]),
                ClassQueue::new(DEFAULT_WEIGHTS[1]),
                ClassQueue::new(DEFAULT_WEIGHTS[2]),
            ],
            min_vruntime: 0,
            current_class: None,
        }
    }

    pub fn scheduler_name() -> &'static str {
        "EEVDF-Class"
    }

    fn count_runnable_classes(&self) -> usize {
        self.classes.iter().filter(|c| c.nr_running > 0).count()
    }

    fn update_min_vruntime(&mut self) {
        let min = self
            .classes
            .iter()
            .filter(|c| c.nr_running > 0)
            .map(|c| c.vruntime)
            .min();
        if let Some(min) = min {
            self.min_vruntime = self.min_vruntime.max(min);
        }
    }

    /// Select the class with the lowest EEVDF deadline among runnable classes.
    fn select_class(&self) -> Option<usize> {
        let nr_runnable = self.count_runnable_classes();
        if nr_runnable == 0 {
            return None;
        }

        let request = (SCHED_PERIOD_TICKS / nr_runnable as u128).max(MIN_SLICE_TICKS);

        let mut best: Option<(usize, u128)> = None;
        for (i, class) in self.classes.iter().enumerate() {
            if class.nr_running == 0 {
                continue;
            }
            let deadline = class.vruntime + request * VRUNTIME_SCALE / class.weight as u128;
            match best {
                None => best = Some((i, deadline)),
                Some((_, best_dl)) if deadline < best_dl => best = Some((i, deadline)),
                _ => {}
            }
        }

        best.map(|(i, _)| i)
    }

    /// Returns true if another class's EEVDF deadline is lower than the
    /// current class's, meaning a class switch would be beneficial.
    fn should_preempt_for_class(&self) -> bool {
        let Some(current_idx) = self.current_class else {
            return false;
        };

        let nr_runnable = self.count_runnable_classes();
        if nr_runnable == 0 {
            return false;
        }

        // The running task was removed from its class queue, so the current
        // class might show nr_running == 0 even though it is active.  Count
        // it as runnable for the deadline computation.
        let effective_runnable = if self.classes[current_idx].nr_running > 0 {
            nr_runnable
        } else {
            nr_runnable + 1
        };

        let request = (SCHED_PERIOD_TICKS / effective_runnable as u128).max(MIN_SLICE_TICKS);
        let current_deadline = self.classes[current_idx].vruntime
            + request * VRUNTIME_SCALE / self.classes[current_idx].weight as u128;

        for (i, class) in self.classes.iter().enumerate() {
            if i == current_idx || class.nr_running == 0 {
                continue;
            }
            let deadline =
                class.vruntime + request * VRUNTIME_SCALE / class.weight as u128;
            if deadline < current_deadline {
                return true;
            }
        }
        false
    }
}

impl<T, const S: usize> BaseScheduler for EevdfClassScheduler<T, S> {
    type SchedItem = Arc<EevdfTask<T, S>>;

    fn init(&mut self) {}

    fn add_task(&mut self, task: Self::SchedItem) {
        let class_idx = task.class_id() as usize;
        assert!(class_idx < NUM_CLASSES, "Invalid class ID");

        let class = &mut self.classes[class_idx];
        if class.nr_running == 0 {
            class.vruntime = class.vruntime.max(self.min_vruntime);
        }

        class.queue.push_back(task);
        class.nr_running += 1;

        self.update_min_vruntime();
    }

    fn remove_task(&mut self, task: &Self::SchedItem) -> Option<Self::SchedItem> {
        let class_idx = task.class_id() as usize;
        if class_idx >= NUM_CLASSES {
            return None;
        }

        let class = &mut self.classes[class_idx];
        let result = unsafe { class.queue.remove(task) };
        if result.is_some() {
            class.nr_running -= 1;
            self.update_min_vruntime();
        }
        result
    }

    fn pick_next_task(&mut self) -> Option<Self::SchedItem> {
        let class_idx = self.select_class()?;
        let class = &mut self.classes[class_idx];
        let task = class.queue.pop_front()?;
        class.nr_running -= 1;

        self.current_class = Some(class_idx);
        self.update_min_vruntime();

        Some(task)
    }

    fn put_prev_task(&mut self, prev: Self::SchedItem, preempt: bool) {
        let class_idx = prev.class_id() as usize;
        assert!(class_idx < NUM_CLASSES, "Invalid class ID");

        let class = &mut self.classes[class_idx];
        if class.nr_running == 0 {
            class.vruntime = class.vruntime.max(self.min_vruntime);
        }

        if prev.time_slice() > 0 && preempt {
            class.queue.push_front(prev);
        } else {
            prev.reset_time_slice();
            class.queue.push_back(prev);
        }
        class.nr_running += 1;

        self.update_min_vruntime();
    }

    fn task_tick(&mut self, current: &Self::SchedItem) -> bool {
        if let Some(class_idx) = self.current_class {
            let class = &mut self.classes[class_idx];
            class.vruntime += VRUNTIME_SCALE / class.weight as u128;
        }

        let old_slice = current.time_slice.fetch_sub(1, Ordering::Release);
        let task_expired = old_slice <= 1;

        let class_preempt = self.should_preempt_for_class();

        task_expired || class_preempt
    }

    fn set_priority(&mut self, task: &Self::SchedItem, prio: isize) -> bool {
        if !(-20..=19).contains(&prio) {
            return false;
        }

        let old_class = task.class_id() as usize;
        let new_class = nice_to_class(prio) as usize;
        if old_class == new_class {
            return true;
        }

        // BaseScheduler::set_priority is called for the *current running task*,
        // which is not necessarily inside any ready queue. However, we also make
        // this logic robust for enqueued tasks by removing it from the queue
        // it currently resides in (if present) and re-inserting into the new class.

        // 1) Try remove from any class queue (task may already be enqueued).
        for idx in 0..NUM_CLASSES {
            if self.classes[idx].nr_running == 0 {
                continue;
            }
            // SAFETY: task is expected to either be in the queue or not. If it is
            // in the queue, we remove it to keep scheduler bookkeeping consistent.
            if let Some(removed_task) = unsafe { self.classes[idx].queue.remove(task) } {
                // Update class id before inserting.
                removed_task.set_class_id(new_class as u8);

                let target = &mut self.classes[new_class];
                if target.nr_running == 0 {
                    target.vruntime = target.vruntime.max(self.min_vruntime);
                }
                target.queue.push_back(removed_task);
                target.nr_running += 1;

                // Decrement old class accounting.
                self.classes[idx].nr_running = self.classes[idx].nr_running.saturating_sub(1);

                // If the removed task was the current running one, keep current_class aligned.
                if self.current_class == Some(idx) {
                    self.current_class = Some(new_class);
                }

                self.update_min_vruntime();
                return true;
            }
        }

        // 2) Not found in any queue: treat as running task.
        task.set_class_id(new_class as u8);
        if self.current_class == Some(old_class) {
            self.current_class = Some(new_class);
        }
        true
    }
}

impl<T, const S: usize> Default for EevdfClassScheduler<T, S> {
    fn default() -> Self {
        Self::new()
    }
}
