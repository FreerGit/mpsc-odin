package mpsc

import "core:log"
import "core:sync"


QueueState :: enum {
    Empty,
    Retry,
    Item,
}

Node :: struct {
    next: Maybe(^Node)
}

Queue :: struct {
    head: ^Node,
    tail: ^Node,
    stub: ^Node,
}

init :: proc(q: ^Queue) {
    sync.atomic_store(&q.head, q.stub)
    // sync.atomic_store_explicit(&q.tail, q.stub, sync.Consume)
}

push :: proc(q: ^Queue, node: ^Node) {
    push_ordered(q, node, node)
}

push_ordered :: proc(q: ^Queue, first: ^Node, last: ^Node) {
    // sync.atomic_store(&last.next, nil)
    prev := sync.atomic_load()
}

main :: proc() {
    context.logger = log.create_console_logger()
    log.debug("hello world")
}