import Foundation

// Checks for which queued Accessibility requests ClickActions lets through (#17 item 5).

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

let actions = ClickActions()

let first = actions.newTicket()
check(!first.isStale, "a new ticket is current")

let second = actions.newTicket()
check(first.isStale, "a later click makes the earlier click's queued work stale")
check(!second.isStale, "and the later click's work is current")

let more = actions.currentTicket()
check(!more.isStale, "more work for the same click is current")
check(!second.isStale, "and doesn't cancel what the click queued before")

let third = actions.newTicket()
check(more.isStale && second.isStale, "a third click makes all earlier work stale")

Thread.sleep(forTimeInterval: ClickActions.Ticket.lifetime + 0.1)
check(third.isStale, "work still queued after its lifetime is dropped, even if no other click came")
check(!actions.currentTicket().isStale, "but a ticket issued now is current")

if failures == 0 {
    print("click action checks passed")
} else {
    print("\(failures) click action check(s) failed")
    exit(1)
}
