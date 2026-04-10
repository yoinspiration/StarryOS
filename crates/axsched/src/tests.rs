macro_rules! def_test_sched {
    ($name: ident, $scheduler: ty, $task: ty) => {
        mod $name {
            use crate::*;
            use alloc::sync::Arc;

            #[test]
            fn test_sched() {
                const NUM_TASKS: usize = 11;

                let mut scheduler = <$scheduler>::new();
                for i in 0..NUM_TASKS {
                    scheduler.add_task(Arc::new(<$task>::new(i)));
                }

                for i in 0..NUM_TASKS * 10 - 1 {
                    let next = scheduler.pick_next_task().unwrap();
                    assert_eq!(*next.inner(), i % NUM_TASKS);
                    // pass a tick to ensure the order of tasks
                    scheduler.task_tick(&next);
                    scheduler.put_prev_task(next, false);
                }

                let mut n = 0;
                while scheduler.pick_next_task().is_some() {
                    n += 1;
                }
                assert_eq!(n, NUM_TASKS);
            }

            #[test]
            fn bench_yield() {
                const NUM_TASKS: usize = 1_000_000;
                const COUNT: usize = NUM_TASKS * 3;

                let mut scheduler = <$scheduler>::new();
                for i in 0..NUM_TASKS {
                    scheduler.add_task(Arc::new(<$task>::new(i)));
                }

                let t0 = std::time::Instant::now();
                for _ in 0..COUNT {
                    let next = scheduler.pick_next_task().unwrap();
                    scheduler.put_prev_task(next, false);
                }
                let t1 = std::time::Instant::now();
                println!(
                    "  {}: task yield speed: {:?}/task",
                    stringify!($scheduler),
                    (t1 - t0) / (COUNT as u32)
                );
            }

            #[test]
            fn bench_remove() {
                const NUM_TASKS: usize = 10_000;

                let mut scheduler = <$scheduler>::new();
                let mut tasks = Vec::new();
                for i in 0..NUM_TASKS {
                    let t = Arc::new(<$task>::new(i));
                    tasks.push(t.clone());
                    scheduler.add_task(t);
                }

                let t0 = std::time::Instant::now();
                for i in (0..NUM_TASKS).rev() {
                    let t = scheduler.remove_task(&tasks[i]).unwrap();
                    assert_eq!(*t.inner(), i);
                }
                let t1 = std::time::Instant::now();
                println!(
                    "  {}: task remove speed: {:?}/task",
                    stringify!($scheduler),
                    (t1 - t0) / (NUM_TASKS as u32)
                );
            }
        }
    };
}

def_test_sched!(fifo, FifoScheduler::<usize>, FifoTask::<usize>);
def_test_sched!(rr, RRScheduler::<usize, 5>, RRTask::<usize, 5>);
def_test_sched!(cfs, CFScheduler::<usize>, CFSTask::<usize>);
def_test_sched!(eevdf, EevdfScheduler::<usize, 5>, EevdfEntity::<usize, 5>);

mod eevdf_tests {
    use crate::*;
    use alloc::sync::Arc;

    #[test]
    fn high_weight_task_gets_earlier_deadline() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        let t_bg = Arc::new(EevdfEntity::<usize, 5>::new(1));
        let t_fg = Arc::new(EevdfEntity::<usize, 5>::new(2));

        // t_bg at nice 19 (low weight), t_fg at nice -20 (high weight)
        sched.add_task(t_bg.clone());
        sched.add_task(t_fg.clone());
        sched.set_priority(&t_bg, 19);
        sched.set_priority(&t_fg, -20);

        // High-weight task should be picked first (earlier deadline).
        let next = sched.pick_next_task().unwrap();
        assert_eq!(*next.inner(), 2);
    }

    #[test]
    fn eligible_task_preferred_over_earlier_deadline() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        let t1 = Arc::new(EevdfEntity::<usize, 5>::new(1));
        let t2 = Arc::new(EevdfEntity::<usize, 5>::new(2));

        sched.add_task(t1.clone());
        sched.add_task(t2.clone());

        // Run t1 for several ticks so its vruntime grows.
        let running = sched.pick_next_task().unwrap();
        assert_eq!(*running.inner(), 1);
        for _ in 0..4 {
            sched.task_tick(&running);
        }
        sched.put_prev_task(running, false);

        // t2 has lower vruntime, so it's eligible and should be picked.
        let next = sched.pick_next_task().unwrap();
        assert_eq!(*next.inner(), 2);
    }

    #[test]
    fn set_priority_rejects_out_of_range() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        let t = Arc::new(EevdfEntity::<usize, 5>::new(1));
        sched.add_task(t.clone());
        assert!(!sched.set_priority(&t, -21));
        assert!(!sched.set_priority(&t, 20));
    }

    #[test]
    fn set_priority_on_running_task() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        let t1 = Arc::new(EevdfEntity::<usize, 5>::new(1));
        let t2 = Arc::new(EevdfEntity::<usize, 5>::new(2));
        sched.add_task(t1.clone());
        sched.add_task(t2.clone());

        let running = sched.pick_next_task().unwrap();
        assert!(sched.set_priority(&running, 10));
        sched.put_prev_task(running, false);
        assert!(sched.pick_next_task().is_some());
    }

    #[test]
    fn preempted_task_keeps_deadline() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        let t = Arc::new(EevdfEntity::<usize, 5>::new(1));
        sched.add_task(t.clone());

        let running = sched.pick_next_task().unwrap();
        let dl_before = running.deadline();
        sched.task_tick(&running);
        // Preempted with remaining slice — deadline should be preserved.
        sched.put_prev_task(running, true);

        let picked = sched.pick_next_task().unwrap();
        assert_eq!(picked.deadline(), dl_before);
    }

    #[test]
    fn preempted_task_expired_deadline_uses_remaining_slice() {
        // When a preempted task's deadline has already passed (e.g. because
        // min_vruntime advanced), the new deadline must be proportional to the
        // *remaining* slice, not the full slice.
        const SLICE: usize = 5;
        let mut sched = EevdfScheduler::<usize, SLICE>::new();
        let t = Arc::new(EevdfEntity::<usize, SLICE>::new(1));
        sched.add_task(t.clone());

        let running = sched.pick_next_task().unwrap();
        // Consume 2 ticks → 3 remaining.
        sched.task_tick(&running);
        sched.task_tick(&running);
        assert_eq!(running.slice_for_test(), 3);

        // Force deadline behind vruntime to simulate the "expired" branch.
        let vr_now = running.vruntime_for_test();
        running.set_deadline_for_test(vr_now - 1);

        sched.put_prev_task(running, true);

        let picked = sched.pick_next_task().unwrap();
        let vr = picked.vruntime_for_test();
        // Deadline must reflect the 3 remaining ticks, not the original 5.
        // deadline_delta(3, 1024) = 3 * 1024²/1024 = 3072
        // deadline_delta(5, 1024) = 5120  ← wrong (would over-reward)
        let expected = vr + 3 * (1024isize * 1024 / 1024); // deadline_delta(3, nice_0_weight)
        assert_eq!(picked.deadline(), expected);
    }

    #[test]
    fn preempted_task_valid_deadline_not_overwritten() {
        // When the deadline is still in the future, it must not be touched even
        // if we would have computed a different value.
        const SLICE: usize = 5;
        let mut sched = EevdfScheduler::<usize, SLICE>::new();
        let t = Arc::new(EevdfEntity::<usize, SLICE>::new(1));
        sched.add_task(t.clone());

        let running = sched.pick_next_task().unwrap();
        let dl_before = running.deadline();
        sched.task_tick(&running);
        // vruntime grew by one delta; deadline is still well ahead.
        assert!(running.vruntime_for_test() < dl_before);

        sched.put_prev_task(running, true);

        let picked = sched.pick_next_task().unwrap();
        assert_eq!(picked.deadline(), dl_before);
    }

    #[test]
    fn deadline_preemption_triggers() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        let t1 = Arc::new(EevdfEntity::<usize, 5>::new(1));
        sched.add_task(t1.clone());

        let running = sched.pick_next_task().unwrap();
        // Run a few ticks (no other task — no preemption).
        assert!(!sched.task_tick(&running));

        // Add a high-priority task while t1 is running.
        let t2 = Arc::new(EevdfEntity::<usize, 5>::new(2));
        sched.add_task(t2.clone());
        sched.set_priority(&t2, -20);

        // Next tick should trigger deadline preemption.
        let should_preempt = sched.task_tick(&running);
        assert!(should_preempt);
    }

    #[test]
    fn stats_count_deadline_preemption_and_pick() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        sched.set_stats_enabled(true);
        let t1 = Arc::new(EevdfEntity::<usize, 5>::new(1));
        sched.add_task(t1.clone());

        let running = sched.pick_next_task().unwrap();
        assert_eq!(sched.stats().picks_total, 1);
        assert!(!sched.task_tick(&running));

        let t2 = Arc::new(EevdfEntity::<usize, 5>::new(2));
        sched.add_task(t2.clone());
        sched.set_priority(&t2, -20);
        assert!(sched.task_tick(&running));
        assert_eq!(sched.stats().preempt_by_deadline, 1);
    }

    #[test]
    fn stats_count_slice_expired() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        sched.set_stats_enabled(true);
        let t = Arc::new(EevdfEntity::<usize, 5>::new(1));
        sched.add_task(t);
        let running = sched.pick_next_task().unwrap();

        for _ in 0..4 {
            assert!(!sched.task_tick(&running));
        }
        assert!(sched.task_tick(&running));
        assert_eq!(sched.stats().slice_expired, 1);
    }

    #[test]
    fn stats_count_fallback_no_eligible() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        sched.set_stats_enabled(true);
        sched.set_debug_force_no_eligible(true);
        let t1 = Arc::new(EevdfEntity::<usize, 5>::new(1));
        let t2 = Arc::new(EevdfEntity::<usize, 5>::new(2));
        sched.add_task(t1);
        sched.add_task(t2);

        let _ = sched.pick_next_task().unwrap();
        let stats = sched.stats();
        assert_eq!(stats.picks_total, 1);
        assert_eq!(stats.fallback_no_eligible, 1);
    }

    #[test]
    fn stats_disabled_does_not_count() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        // Keep default: stats disabled.
        let t1 = Arc::new(EevdfEntity::<usize, 5>::new(1));
        let t2 = Arc::new(EevdfEntity::<usize, 5>::new(2));
        sched.add_task(t1.clone());
        sched.add_task(t2.clone());

        let running = sched.pick_next_task().unwrap();
        let _ = sched.task_tick(&running);
        sched.put_prev_task(running, false);
        let _ = sched.pick_next_task().unwrap();

        let stats = sched.stats();
        assert_eq!(stats.picks_total, 0);
        assert_eq!(stats.preempt_by_deadline, 0);
        assert_eq!(stats.slice_expired, 0);
        assert_eq!(stats.fallback_no_eligible, 0);
    }

    #[test]
    fn stats_reset_clears_counters() {
        let mut sched = EevdfScheduler::<usize, 5>::new();
        sched.set_stats_enabled(true);
        let t1 = Arc::new(EevdfEntity::<usize, 5>::new(1));
        sched.add_task(t1.clone());
        let running = sched.pick_next_task().unwrap();
        // Consume full slice so we have non-zero stats.
        for _ in 0..5 {
            let _ = sched.task_tick(&running);
        }

        let before = sched.stats();
        assert!(before.picks_total > 0 || before.slice_expired > 0);
        sched.reset_stats();
        let after = sched.stats();
        assert_eq!(after.picks_total, 0);
        assert_eq!(after.preempt_by_deadline, 0);
        assert_eq!(after.slice_expired, 0);
        assert_eq!(after.fallback_no_eligible, 0);
    }
}

// ── per_cpu tests ────────────────────────────────────────────────────────────

mod per_cpu_tests {
    use alloc::sync::Arc;
    use crate::per_cpu::{HasSchedulerId, PerCpuScheduler, SchedulerKind};
    use crate::BaseScheduler;
    use core::sync::atomic::{AtomicU64, Ordering};

    // A minimal task type for testing – no scheduler-specific fields.
    struct Task {
        id:   u64,
        name: &'static str,
    }

    impl Task {
        fn new(id: u64, name: &'static str) -> Arc<Self> {
            Arc::new(Self { id, name })
        }
    }

    impl HasSchedulerId for Task {
        fn sched_id(&self) -> u64 { self.id }
    }

    // ── basic scheduling for each variant ────────────────────────────────

    #[test]
    fn fifo_picks_in_insertion_order() {
        let mut s = PerCpuScheduler::<Task>::new(SchedulerKind::Fifo);
        for id in 0..5u64 {
            s.add_task(Task::new(id, "t"));
        }
        for expected in 0..5u64 {
            let t = s.pick_next_task().unwrap();
            assert_eq!(t.id, expected);
            s.put_prev_task(t, false);
        }
    }

    #[test]
    fn fifo_never_preempts_on_tick() {
        let mut s = PerCpuScheduler::<Task>::new(SchedulerKind::Fifo);
        s.add_task(Task::new(0, "t"));
        let t = s.pick_next_task().unwrap();
        // No matter how many ticks pass, FIFO never requests preemption.
        for _ in 0..100 {
            assert!(!s.task_tick(&t), "FIFO should not preempt");
        }
        s.put_prev_task(t, false);
    }

    #[test]
    fn rr_preempts_after_slice_expires() {
        let mut s = PerCpuScheduler::<Task>::new(SchedulerKind::Rr);
        s.add_task(Task::new(0, "t"));
        let t = s.pick_next_task().unwrap();
        // DEFAULT_TIME_SLICE = 5; the 5th tick should trigger preemption.
        let mut preempted = false;
        for _ in 0..10 {
            if s.task_tick(&t) { preempted = true; break; }
        }
        assert!(preempted, "RR must preempt after slice expires");
        s.put_prev_task(t, true);
    }

    #[test]
    fn eevdf_fairness_equal_weight() {
        // Three equal-weight tasks; after many ticks each should get ~1/3 of CPU.
        let mut s = PerCpuScheduler::<Task>::new(SchedulerKind::Eevdf);
        let tasks: Vec<_> = (0..3u64).map(|i| Task::new(i, "t")).collect();
        for t in &tasks { s.add_task(t.clone()); }

        let mut counts = [0u64; 3];
        const TICKS: u64 = 6000;

        for _ in 0..TICKS {
            let t = s.pick_next_task().unwrap();
            let id = t.id as usize;
            let preempt = s.task_tick(&t);
            counts[id] += 1;
            s.put_prev_task(t, preempt);
        }

        let expected = TICKS / 3;
        for (i, &got) in counts.iter().enumerate() {
            let err = (got as f64 - expected as f64).abs() / expected as f64;
            assert!(
                err < 0.05,
                "task {i}: expected ~{expected} ticks, got {got} ({:.1}% off)",
                err * 100.0
            );
        }
    }

    // ── cross-scheduler migration ─────────────────────────────────────────

    /// Demonstrates the key benefit of metadata separation: the same Arc<Task>
    /// can be moved from an EEVDF scheduler to a FIFO scheduler without any
    /// type conversion.
    #[test]
    fn task_migrates_between_schedulers() {
        let mut eevdf = PerCpuScheduler::<Task>::new(SchedulerKind::Eevdf);
        let mut fifo  = PerCpuScheduler::<Task>::new(SchedulerKind::Fifo);

        // Add tasks to EEVDF, run for a while so they accumulate vruntime.
        let t0 = Task::new(0, "migrating");
        let t1 = Task::new(1, "staying");
        eevdf.add_task(t0.clone());
        eevdf.add_task(t1.clone());

        for _ in 0..20 {
            let t = eevdf.pick_next_task().unwrap();
            let preempt = eevdf.task_tick(&t);
            eevdf.put_prev_task(t, preempt);
        }

        // Migrate task 0 from EEVDF to FIFO — no type conversion needed.
        let migrated = eevdf.remove_task(&t0).expect("task should be in eevdf queue");
        fifo.add_task(migrated);

        // FIFO should now schedule the migrated task normally.
        let picked = fifo.pick_next_task().expect("fifo should have the migrated task");
        assert_eq!(picked.id, 0, "migrated task should be scheduled by fifo");
        fifo.put_prev_task(picked, false);

        // EEVDF continues with the remaining task without issues.
        let remaining = eevdf.pick_next_task().expect("eevdf should still have task 1");
        assert_eq!(remaining.id, 1);
    }
}

mod eevdf_fairness {
    use crate::*;
    use alloc::sync::Arc;
    use alloc::vec::Vec;

    /// Run a single-CPU scheduling simulation for `total_ticks` ticks.
    ///
    /// Each entry in `task_nice` is `(task, nice_value)`. Returns a vector
    /// where `counts[i]` is the number of ticks task `i` actually ran.
    fn simulate<const S: usize>(
        task_nice: &[(Arc<EevdfEntity<usize, S>>, isize)],
        total_ticks: u64,
    ) -> Vec<u64> {
        let mut sched = EevdfScheduler::<usize, S>::new();
        for (task, nice) in task_nice {
            sched.add_task(task.clone());
            sched.set_priority(task, *nice);
        }

        let n = task_nice.len();
        let mut counts = alloc::vec![0u64; n];
        let mut current = sched.pick_next_task().unwrap();
        let mut elapsed = 0u64;

        loop {
            counts[*current.inner()] += 1;
            elapsed += 1;

            let should_switch = sched.task_tick(&current);
            if should_switch || elapsed >= total_ticks {
                // Preempted mid-slice vs. slice-expired/yield.
                let preempt = should_switch && current.slice_for_test() > 0;
                sched.put_prev_task(current, preempt);
                if elapsed >= total_ticks {
                    break;
                }
                current = sched.pick_next_task().unwrap();
            }
        }

        counts
    }

    #[test]
    fn equal_weight_tasks_share_cpu_evenly() {
        // 3 tasks at nice 0 (weight 1024 each) — each should get ≈ 1/3 of CPU.
        const S: usize = 5;
        const N: usize = 3;
        const TOTAL: u64 = 9_000; // divisible by 3 for clean expected value

        let tasks: Vec<_> = (0..N)
            .map(|i| (Arc::new(EevdfEntity::<usize, S>::new(i)), 0isize))
            .collect();

        let counts = simulate(&tasks, TOTAL);

        let expected = TOTAL / N as u64; // 3 000 ticks each
        for (i, &got) in counts.iter().enumerate() {
            let err = (got as f64 - expected as f64).abs() / expected as f64;
            assert!(
                err < 0.05,
                "task {i}: expected ~{expected} ticks, got {got} ({:.1}% error)",
                err * 100.0,
            );
        }
    }

    #[test]
    fn weighted_tasks_get_proportional_cpu() {
        // nice -5 → weight 3121, nice 0 → weight 1024, nice 5 → weight 335
        // Expected CPU shares: ≈ 69.7% / 22.9% / 7.5%
        const S: usize = 5;
        const TOTAL: u64 = 15_000;

        let nice_vals = [-5isize, 0, 5];
        let weights = [3121isize, 1024, 335];
        let total_weight: isize = weights.iter().sum(); // 4 480

        let tasks: Vec<_> = (0..3)
            .map(|i| (Arc::new(EevdfEntity::<usize, S>::new(i)), nice_vals[i]))
            .collect();

        let counts = simulate(&tasks, TOTAL);

        for (i, (&got, &w)) in counts.iter().zip(weights.iter()).enumerate() {
            let expected = TOTAL as f64 * w as f64 / total_weight as f64;
            let err = (got as f64 - expected).abs() / expected;
            assert!(
                err < 0.10,
                "task {i} (weight {w}): expected ~{expected:.0} ticks, got {got} ({:.1}% error)",
                err * 100.0,
            );
        }
    }
}
