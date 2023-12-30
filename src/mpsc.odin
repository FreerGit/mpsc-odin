package mpsc

import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"

PollState :: enum {
	Empty,
	Retry,
	Item,
}

Node :: struct($T: typeid) {
	next:  ^Node(T),
	value: T,
}

Queue :: struct($T: typeid) {
	head: ^Node(T),
	tail: ^Node(T),
	stub: Node(T),
}

init :: proc(q: ^Queue($T)) {
	sync.atomic_store(&q.head, &q.stub)
	sync.atomic_store(&q.tail, &q.stub)
	sync.atomic_store(&q.stub.next, nil)
}

push :: proc(q: ^Queue($T), node: ^Node(T)) {
	push_ordered(q, node, node)
}

// Note that first and lats must be linked appropiately by the user
push_ordered :: proc(q: ^Queue($T), first: ^Node(T), last: ^Node(T)) {
	sync.atomic_store(&last.next, nil)
	prev := sync.atomic_load(&q.head)
	sync.atomic_store(&q.head, last)
	sync.atomic_store(&prev.next, first)
}

push_unordered :: proc(q: ^Queue($T), nodes: []^Node(T)) {
	if len(nodes) == 0 {
		return
	}

	first := nodes[0]
	last := nodes[len(nodes) - 1]

	i := 0
	for i < len(nodes) - 1 {
		sync.atomic_store(&nodes[i].next, nodes[i + 1])
		i += 1
	}

	push_ordered(q, first, last)
}

is_empty :: proc(q: ^Queue($T)) -> bool {
	tail := sync.atomic_load(&q.tail)
	next := sync.atomic_load(&q.tail.next)
	head := sync.atomic_load(&q.head)
	return tail == &q.stub && next == nil && tail == head
}

get_tail :: proc(q: ^Queue($T)) -> ^Node(T) {
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

get_next :: proc(q: ^Queue($T), prev: ^Node(T)) -> ^Node(T) {
	next := sync.atomic_load(&prev.next)

	if next != nil {
		if next == &q.stub {
			next = sync.atomic_load(&next.next)
		}
	}
	return next
}


// Check if ready to consume the front node in the queue
poll :: proc(q: ^Queue($T)) -> (state: PollState, node: ^Node(T)) {
	head: ^Node(T)
	tail := sync.atomic_load(&q.tail)
	next := sync.atomic_load(&tail.next)

	if tail == &q.stub {
		if next != nil {
			sync.atomic_store(&q.tail, next)
			tail = next
			next = sync.atomic_load(&tail.next)
		} else {
			head = sync.atomic_load(&q.head)
			if tail != head do return .Retry, nil
			return .Empty, nil
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

pop :: proc(q: ^Queue($T)) -> ^Node(T) {
	state := PollState.Retry
	node: ^Node(T)
	for state == PollState.Retry {
		state, node := poll(q)
		if state == PollState.Empty {
			return nil
		}
	}
	return node
}


thread_proc1 :: proc(q: ^Queue(T = int), wg: ^sync.Wait_Group) {
	elements: [500]Node(int)
	for ele, idx in &elements {
		ele.value = idx
		push(q, &ele)
	}
	sync.wait_group_done(wg)
}

thread_proc2 :: proc(q: ^Queue(T = int), wg: ^sync.Wait_Group) {
	elements: [250]Node(int)
	for ele, idx in &elements {
		ele.value = idx
		push(q, &ele)
	}
	sync.wait_group_done(wg)
}


@(test)
threaded_push_get :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()
	log.debug("starting threads...")
	wg: sync.Wait_Group
	q: Queue(int)
	init(&q)
	sync.wait_group_add(&wg, 3)
	thread.create_and_start_with_poly_data2(&q, &wg, thread_proc1)
	thread.create_and_start_with_poly_data2(&q, &wg, thread_proc2)
	thread.create_and_start_with_poly_data2(&q, &wg, thread_proc2)
	sync.wait(&wg)

	testing.expect(t, !is_empty(&q))

	node_tail := get_tail(&q)
	i := 0
	for node_tail != nil {
		i += 1
		node_tail = get_next(&q, node_tail)
	}
	testing.expect(t, !is_empty(&q))
	testing.expect(t, i == 1000)
}

@(test)
ordered_push_get_pop :: proc(t: ^testing.T) {
	// Setup testing && queue
	context.logger = log.create_console_logger()
	elements: [5]Node(int)
	queue: Queue(int)
	init(&queue)

	// Push elements to queue
	for ele, idx in &elements {
		ele.value = idx
		push(&queue, &ele)
	}

	testing.expect(t, !is_empty(&queue))

	// Get the tail, assert correct order.
	node_tail := get_tail(&queue)
	i := 0
	for node_tail != nil {
		testing.expect(t, &elements[i] == node_tail)
		i += 1
		node_tail = get_next(&queue, node_tail)
	}

	// Queue should not be empty, we did not pop, just get!
	testing.expect(t, !is_empty(&queue))

	// Pop all the elements, then assert empty
	node := pop(&queue)
	i = 0
	for node_tail != nil {
		// testing.expect(t, &elements[i].next == node_tail)
		i += 1
		node_tail = pop(&queue)
	}

	testing.expect(t, is_empty(&queue))
}

@(test)
unordered_push_get_pop :: proc(t: ^testing.T) {
	elements: [1000]Node(int)
	nodes: [1000]^Node(int)
	queue: Queue(int)
	init(&queue)

	for ele, idx in &elements {
		ele.value = idx
		nodes[idx] = &ele
	}

	push_unordered(&queue, nodes[:])
	testing.expect(t, !is_empty(&queue))

	node := get_tail(&queue)
	for i := 0; node != nil; i += 1 {
		testing.expect(t, &elements[i] == node)
		node = get_next(&queue, node)
	}

	testing.expect(t, !is_empty(&queue))

	node = pop(&queue)
	for i := 0; node != nil; i += 1 {
		testing.expect(t, &elements[i] == node)
		node = pop(&queue)
	}

	testing.expect(t, is_empty(&queue))
}

@(private)
assert_poll_result :: proc(state: PollState, node: ^Node, in_state: PollState) -> bool {
	if in_state == .Item {
		return state == in_state && node != nil
	} else {
		return state == in_state && node == nil
	}
}

@(test)
partial_push_poll :: proc(t: ^testing.T) {
	elements: [3]Node(int)
	prevs: [3]^Node(int)
	queue: Queue(int)
	init(&queue)

	for ele, idx in &elements {
		ele.value = 1
	}

	testing.expect(t, assert_poll_result(poll(&queue), .Empty))
	testing.expect(t, is_empty(&queue))

	push(&queue, &elements[0])
	testing.expect(t, !is_empty(&queue))

	testing.expect(t, assert_poll_result(poll(&queue), .Item))

	testing.expect(t, assert_poll_result(poll(&queue), .Empty))

	push(&queue, &elements[0])
	push(&queue, &elements[1])
	testing.expect(t, !is_empty(&queue))

	testing.expect(t, assert_poll_result(poll(&queue), .Item))
	testing.expect(t, !is_empty(&queue))

	testing.expect(t, assert_poll_result(poll(&queue), .Item))
	testing.expect(t, is_empty(&queue))

	testing.expect(t, assert_poll_result(poll(&queue), .Empty))
	testing.expect(t, is_empty(&queue))

	sync.atomic_store(&elements[0].next, nil)
	prevs[0] = sync.atomic_load(&queue.head)
	sync.atomic_store(&queue.head, &elements[0])
	testing.expect(t, assert_poll_result(poll(&queue), .Retry))
	testing.expect(t, assert_poll_result(poll(&queue), .Retry))

	sync.atomic_store(&prevs[0].next, &elements[0])
	testing.expect(t, assert_poll_result(poll(&queue), .Item))
	testing.expect(t, assert_poll_result(poll(&queue), .Empty))

	push(&queue, &elements[0])
	push(&queue, &elements[1])
	sync.atomic_store(&elements[2].next, nil)
	prevs[2] = sync.atomic_load(&queue.head)
	sync.atomic_store(&queue.head, &elements[2])
	testing.expect(t, assert_poll_result(poll(&queue), .Item))
	testing.expect(t, assert_poll_result(poll(&queue), .Retry))
	testing.expect(t, assert_poll_result(poll(&queue), .Retry))

	sync.atomic_store(&prevs[2].next, &elements[2])
	testing.expect(t, assert_poll_result(poll(&queue), .Item))
	testing.expect(t, assert_poll_result(poll(&queue), .Item))
	testing.expect(t, assert_poll_result(poll(&queue), .Empty))

	push(&queue, &elements[0])

	tail := sync.atomic_load(&queue.tail)
	next := sync.atomic_load(&tail.next)
	head: ^Node(int)
	node: ^Node(int)
	is_done := false

	if tail == &queue.stub {
		if next != nil {
			sync.atomic_store(&queue.tail, next)
			tail = next
			next = sync.atomic_load(&tail.next)
		} else {
			head = sync.atomic_load(&queue.head)
			if tail != head {
				is_done = true
			} else {
				is_done = true
			}
		}
	}

	if next != nil {
		sync.atomic_store(&queue.tail, next)
		is_done = true
		node = tail
	}

	head = sync.atomic_load(&queue.head)
	if tail != head {
		is_done = true
	}

	testing.expect(t, !is_done)

	sync.atomic_store(&elements[1].next, nil)
	prevs[1] = sync.atomic_load(&queue.head)
	sync.atomic_store(&queue.head, &elements[1])

	push(&queue, &queue.stub)

	poll_state := PollState.Retry

	next = sync.atomic_load(&tail.next)
	if next != nil {
		sync.atomic_store(&queue.tail, next)
		poll_state := PollState.Item
		node = tail
	}

	testing.expect(t, poll_state == PollState.Retry)

	sync.atomic_store(&prevs[1].next, &elements[1])
	state, poll_node := poll(&queue)
	testing.expect(t, assert_poll_result(state, poll_node, .Item))
	testing.expect(t, &elements[0] == poll_node)
	state, poll_node = poll(&queue)
	testing.expect(t, assert_poll_result(state, poll_node, .Item))
	testing.expect(t, &elements[1] == poll_node)
	state, poll_node = poll(&queue)
	testing.expect(t, assert_poll_result(state, poll_node, .Empty))
}
