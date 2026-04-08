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
