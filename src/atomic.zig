const std = @import("std");

// A blocking SPSC queue, used so that threads can sleep while waiting
// for another thread to pass them data.
pub fn BlockingQueue(comptime T: type) type {
    return struct {
        inner: std.DoublyLinkedList(T),
        mutex: std.Thread.Mutex,
        event: std.Thread.ResetEvent,
        alloc: std.mem.Allocator,
        // arena: std.heap.ArenaAllocator,

        pub const Self = @This();
        pub const Node = std.DoublyLinkedList(T).Node;

        pub fn init(alloc: *std.mem.Allocator) Self {
            // const arena = std.heap.ArenaAllocator.init(alloc.*);
            return .{
                .inner = std.DoublyLinkedList(T){},
                .mutex = std.Thread.Mutex{},
                .event = std.Thread.ResetEvent{},
                // .arena = arena,
                .alloc = alloc.*,
            };
        }

        pub fn put(self: *Self, i: T) !void {
            // const alloc = self.arena.allocator();
            const node = try self.alloc.create(Node);
            node.* = .{
                .prev = null,
                .next = null,
                .data = i,
            };
            self.mutex.lock();
            defer self.mutex.unlock();

            self.inner.append(node);
            self.event.set();
        }

        pub fn get(self: *Self) T {
            self.event.wait();

            self.mutex.lock();
            defer self.mutex.unlock();

            const node = self.inner.popFirst() orelse std.debug.panic("Could not get node", .{});

            defer self.alloc.destroy(node);
            self.check_flag();

            return node.data;
        }

        /// Must be called with the lock held
        fn check_flag(self: *Self) void {
            // Manually check the state of the queue, as isEmpty() would
            // also try to lock the mutex, causing a deadlock
            if (self.inner.first == null) {
                self.event.reset();
            }
        }

        pub fn try_get(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.inner.popFirst()) |node| {
                defer self.alloc.destroy(node);
                self.check_flag();
                return node.data;
            }
            return null;
        }
    };
}
