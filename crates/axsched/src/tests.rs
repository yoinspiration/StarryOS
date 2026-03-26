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
def_test_sched!(eevdf_class, EevdfClassScheduler::<usize, 5>, EevdfTask::<usize, 5>);

mod eevdf_priority {
    use crate::*;
    use alloc::sync::Arc;

    #[test]
    fn test_set_priority_reorders_enqueued_task() {
        let mut scheduler = EevdfClassScheduler::<usize, 5>::new();
        let t1 = Arc::new(EevdfTask::<usize, 5>::new(1));
        let t2 = Arc::new(EevdfTask::<usize, 5>::new(2));

        scheduler.add_task(t1.clone());
        scheduler.add_task(t2.clone());

        // Move t2 to interactive class; it should be preferred next.
        assert!(scheduler.set_priority(&t2, -20));
        let next = scheduler.pick_next_task().unwrap();
        assert_eq!(*next.inner(), 2);
    }

    #[test]
    fn test_set_priority_rejects_out_of_range_nice() {
        let mut scheduler = EevdfClassScheduler::<usize, 5>::new();
        let t = Arc::new(EevdfTask::<usize, 5>::new(1));
        scheduler.add_task(t.clone());

        assert!(!scheduler.set_priority(&t, -21));
        assert!(!scheduler.set_priority(&t, 20));
    }

    #[test]
    fn test_set_priority_on_running_task_keeps_scheduler_consistent() {
        let mut scheduler = EevdfClassScheduler::<usize, 5>::new();
        let t1 = Arc::new(EevdfTask::<usize, 5>::new(1));
        let t2 = Arc::new(EevdfTask::<usize, 5>::new(2));
        scheduler.add_task(t1.clone());
        scheduler.add_task(t2.clone());

        // t1 becomes running (popped from queue).
        let running = scheduler.pick_next_task().unwrap();
        assert_eq!(*running.inner(), 1);

        // Changing priority of the running task should not panic or corrupt state.
        assert!(scheduler.set_priority(&running, 19));

        // Put it back and ensure scheduler still returns tasks.
        scheduler.put_prev_task(running, false);
        assert!(scheduler.pick_next_task().is_some());
    }
}
