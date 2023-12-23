package mpsc

import "core:log"
import "core:sync"
import "core:reflect"
import "core:testing"
import "core:os"


PollState :: enum {
    Empty,
    Retry,
    Item,
}

Node :: struct {
    next: ^Node
}

Queue :: struct {
    head: ^Node,
    tail: ^Node,
    stub: Node,
}

init :: proc(q: ^Queue) {
    sync.atomic_store(&q.head, &q.stub)
    sync.atomic_store(&q.tail, &q.stub)
    sync.atomic_store(&q.stub.next, nil)
}

push :: proc(q: ^Queue, node: ^Node) {
    push_ordered(q, node, node)
}

// Note that first and lats must be linked appropiately by the user
push_ordered :: proc(q: ^Queue, first: ^Node, last: ^Node) {
    sync.atomic_store(&last.next, nil)
    prev := sync.atomic_load(&q.head)
    sync.atomic_store(&q.head,last) 
    sync.atomic_store(&prev.next, first)
}

push_unordered :: proc(q: ^Queue, nodes: []^Node) {
    if len(nodes) == 0 {
        return
    }

    first := nodes[0]
    last := nodes[len(nodes) - 1]

    i :=  0
    for i < len(nodes) - 1 {
        sync.atomic_store(&nodes[i].next, nodes[i+1])
        i += 1
    }

    push_ordered(q, first, last)
}

is_empty :: proc(q: ^Queue) -> bool {
    tail := sync.atomic_load(&q.tail)
    next := sync.atomic_load(&q.tail.next)
    head := sync.atomic_load(&q.head)
    return tail == &q.stub && next == nil && tail == head
}

get_tail :: proc(q: ^Queue) -> ^Node {
    tail := sync.atomic_load(&q.tail)
    next := sync.atomic_load(&tail.next)
    if tail == &q.stub {
        if next != nil {
            sync.atomic_store(&q.tail, next)
            tail = next
        } else {
            return nil
        }
    }
    return tail
}

get_next :: proc(q: ^Queue, prev: ^Node) -> ^Node {
    next := sync.atomic_load(&prev.next)

    if next != nil {
        if next == &q.stub {
            next = sync.atomic_load(&next.next)
        }
    }
    return next
}


// Check if ready to consume the front node in the queue
poll :: proc(q: ^Queue) -> (state: PollState, node: ^Node) {
    head: ^Node
    tail := sync.atomic_load(&q.tail)
    next := sync.atomic_load(&tail.next)

    if tail == &q.stub {
        if next != nil {
            sync.atomic_store(&q.tail, next)
            tail = next
            next = sync.atomic_load(&tail.next)
        } else {
            head = sync.atomic_load(&q.head)
            if tail != head {
                return .Retry, nil
            } else {
                return .Empty, nil
            }
        }
    }

    if next != nil {
        sync.atomic_store(&q.tail, next)
        return .Item, tail
    }

    head = sync.atomic_load(&q.head)
    if tail != head {
        return .Retry, nil
    }

    push(q, &q.stub)

    next = sync.atomic_load(&tail.next)
    if next != nil {
        sync.atomic_store(&q.tail, next)
        return .Item, tail
    }

    return .Retry, nil
}

pop :: proc(q: ^Queue) -> ^Node {
    state := PollState.Retry
    node: ^Node
    for state == PollState.Retry {
        state, node := poll(q)
        if state == PollState.Empty {
            return nil
        }
    }
    return node
}


main :: proc() {
    context.logger = log.create_console_logger()
}


Element :: struct {
    node: Node,
    id: int,
}

@(test)
ordered_push_get_pop :: proc(t: ^testing.T) {
    // Setup testing && queue
    context.logger = log.create_console_logger()
    elements : [5]Element
    queue: Queue
    init(&queue)

    // Push elements to queue
    for ele, idx in &elements {
        ele.id = idx
        push(&queue, &ele.node)
    }

    testing.expect(t,!is_empty(&queue))

    // Get the tail, assert correct order.
    node_tail := get_tail(&queue)
    i := 0
    for node_tail != nil {
        testing.expect(t, &elements[i].node == node_tail)
        i += 1
        node_tail = get_next(&queue, node_tail)
    }

    // Queue should not be empty, we did not pop, just get!
    testing.expect(t, !is_empty(&queue))

    // Pop all the elements, then assert empty
    node := pop(&queue)
    i = 0
    for node_tail != nil {
        testing.expect(t, &elements[i].node == node_tail)
        i += 1
        node_tail = pop(&queue)
    }

    testing.expect(t,is_empty(&queue))
}

@(test)
unordered_push_get_pop :: proc(t: ^testing.T) {
    elements : [1000]Element
    nodes : [1000]^Node
    queue : Queue
    init(&queue)

    for ele, idx in &elements {
        ele.id = idx
        nodes[idx] = &ele.node    
    }

    push_unordered(&queue, nodes[:])
    testing.expect(t, !is_empty(&queue))

    node := get_tail(&queue)
    for i := 0; node != nil; i += 1 {
        testing.expect(t, &elements[i].node == node)
        node = get_next(&queue, node)
    }

    testing.expect(t, !is_empty(&queue))

    node = pop(&queue)
    for i := 0; node != nil; i += 1 {
        testing.expect(t, &elements[i].node == node)
        node = pop(&queue)
    }

    testing.expect(t, is_empty(&queue))
}