# Heartbeat driver: advance sim in chunks and report sim time so we can
# see whether progress is happening between $display boundaries.
set prev -1
set stale 0
for {set i 0} {$i < 100000} {incr i} {
    if {[catch {run 100 us} msg]} {
        puts "HB-DONE: run errored at [current_time] ($msg)"
        exit
    }
    set now [current_time]
    puts "HB [clock format [clock seconds] -format %H:%M:%S]: t = $now"
    if {$now eq $prev} {
        incr stale
        if {$stale >= 2} {
            puts "HB-DONE: sim time not advancing (finished or halted) at $now"
            exit
        }
    } else {
        set stale 0
    }
    set prev $now
}
