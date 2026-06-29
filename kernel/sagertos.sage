## kernel/sagertos.sage — SageRTOS: Pure-Sage Cooperative Scheduler
##
## Runs inside MetalRV64VM on bare-metal RISC-V.
## Provides task registration and a cooperative scheduling loop.
##
## Architecture:
##   Tasks are closures registered via rtos_spawn(name, func).
##   rtos_run() starts the scheduler loop: round-robin, cooperative.
##   Tasks yield by returning; the scheduler calls the next task.
##   The shell is registered as the primary foreground task.

let rtos_tasks     = []
let rtos_count     = 0
let rtos_current   = 0
let rtos_running   = true

proc rtos_init():
    rtos_tasks = array(8)
    for i in range(8):
        push(rtos_tasks, nil)
    rtos_count = 0
    rtos_current = 0

proc rtos_spawn(name, task_func):
    let entry = {}
    entry.name = name
    entry.func = task_func
    push(rtos_tasks, entry)
    rtos_count = rtos_count + 1

proc rtos_run():
    print("SageRTOS: starting scheduler (")
    print(str(rtos_count))
    print(" tasks)\n")

    while rtos_running and rtos_count > 0:
        let entry = rtos_tasks[rtos_current]
        if entry != nil:
            entry.func()
        rtos_current = (rtos_current + 1) % rtos_count

proc rtos_halt():
    rtos_running = false

proc rtos_idle():
    ## Called when no tasks are ready
    pass
