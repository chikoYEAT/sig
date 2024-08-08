const std = @import("std");
const sig = @import("../lib.zig");

const Allocator = std.mem.Allocator;
const AutoArrayHashMap = std.AutoArrayHashMap;
const AtomicBool = std.atomic.Value(bool);
const AtomicSlot = std.atomic.Value(Slot);
const Thread = std.Thread;

const Epoch = sig.core.Epoch;
const Slot = sig.core.Slot;
const Pubkey = sig.core.Pubkey;
const Hash = sig.core.Hash;
const RwMux = sig.sync.RwMux;
const Signature = sig.core.Signature;
const Channel = sig.sync.Channel;
const SocketAddr = sig.net.SocketAddr;
const Duration = sig.time.Duration;
const Instant = sig.time.Instant;
const ContactInfo = sig.gossip.ContactInfo;
const GossipTable = sig.gossip.GossipTable;
const RpcClient = sig.rpc.Client;
const RpcEpochInfo = sig.rpc.Client.EpochInfo;
const RpcLeaderSchedule = sig.rpc.Client.LeaderSchedule;
const RpcLatestBlockhash = sig.rpc.Client.LatestBlockhash;
const LeaderSchedule = sig.core.leader_schedule.SingleEpochLeaderSchedule;

const NUM_CONSECUTIVE_LEADER_SLOTS = sig.core.leader_schedule.NUM_CONSECUTIVE_LEADER_SLOTS;

/// Maximum size of the transaction retry poolx
const MAX_PENDING_POOL_SIZE: usize = 10_000; // This seems like a lot but maybe it needs to be bigger one day

/// Default retry interval
const DEFAULT_PROCESS_TRANSACTIONS_RATE: Duration = Duration.fromSecs(2);

/// Default number of leaders to forward transactions to
const DEFAULT_LEADER_FORWARD_COUNT: u64 = 2;

/// Default max number of time the service will retry broadcast
const DEFAULT_MAX_RETRIES: ?usize = null;
const DEFAULT_SERVICE_MAX_RETRIES: usize = std.math.maxInt(usize);

/// Default batch size for sending transaction in batch
/// When this size is reached, send out the transactions.
const DEFAULT_BATCH_SIZE: usize = 1;

// The maximum transaction batch size
const MAX_TRANSACTION_BATCH_SIZE: usize = 10_000;

/// Maximum transaction sends per second
const MAX_TRANSACTION_SENDS_PER_SECOND: u64 = 1_000;

/// Default maximum batch waiting time in ms. If this time is reached,
/// whatever transactions are cached will be sent.
const DEFAULT_BATCH_SEND_RATE = Duration.fromMillis(1);

// The maximum transaction batch send rate in MS
const MAX_BATCH_SEND_RATE_MS: usize = 100_000;

/// The maximum duration the retry thread may be configured to sleep before
/// processing the transactions that need to be retried.
const MAX_RETRY_SLEEP = Duration.fromSecs(1);

/// The leader info refresh rate.
const LEADER_INFO_REFRESH_RATE = Duration.fromSecs(1);

/// Report the send transaction memtrics for every 5 seconds.
const SEND_TRANSACTION_METRICS_REPORT_RATE = Duration.fromSecs(5);

/// Type to for pending transactions
const PendingTransactions = AutoArrayHashMap(Signature, TransactionInfo);

pub fn run(
    gossip_table_rw: *RwMux(GossipTable),
    channel: *Channel(TransactionInfo),
    exit: *AtomicBool,
) !void {
    const allocator = std.heap.page_allocator;

    const pending_transactions = PendingTransactions.init(allocator);
    var pending_transactions_rw = RwMux(PendingTransactions).init(pending_transactions);

    const service_info = try ServiceInfo.init(allocator, gossip_table_rw);
    var service_info_rw = RwMux(ServiceInfo).init(service_info);

    const refresh_service_info_handle = try Thread.spawn(
        .{},
        refreshServiceInfoThread,
        .{
            allocator,
            &service_info_rw,
            exit,
        },
    );

    const receive_transactions_handle = try Thread.spawn(
        .{},
        receiveTransactionsThread,
        .{
            allocator,
            channel,
            &service_info_rw,
            &pending_transactions_rw,
            exit,
        },
    );

    const process_transactions_handle = try Thread.spawn(
        .{},
        processTransactionsThread,
        .{
            allocator,
            &service_info_rw,
            &pending_transactions_rw,
            exit,
        },
    );

    const mock_transaction_generator_handle = try Thread.spawn(
        .{},
        mockTransactionGenerator,
        .{
            allocator,
            channel,
            &service_info_rw,
            exit,
        },
    );

    refresh_service_info_handle.join();
    receive_transactions_handle.join();
    process_transactions_handle.join();
    mock_transaction_generator_handle.join();
}

fn refreshServiceInfoThread(
    allocator: Allocator,
    service_info_rw: *RwMux(ServiceInfo),
    exit: *AtomicBool,
) !void {
    errdefer exit.store(true, .unordered);

    while (!exit.load(.unordered)) {
        std.time.sleep(ServiceInfo.REFERENCE_SLOT_REFRESH_RATE.asNanos());

        var service_info_lock = service_info_rw.write();
        defer service_info_lock.unlock();
        var service_info: *ServiceInfo = service_info_lock.mut();

        try service_info.refresh(allocator);
    }
}

fn receiveTransactionsThread(
    allocator: Allocator,
    receiver: *Channel(TransactionInfo),
    service_info_rw: *RwMux(ServiceInfo),
    pending_transactions_rw: *RwMux(PendingTransactions),
    exit: *AtomicBool,
) !void {
    errdefer exit.store(true, .unordered);

    var last_batch_sent = try Instant.now();
    var transaction_batch = PendingTransactions.init(allocator);
    defer transaction_batch.deinit();

    while (!exit.load(.unordered)) {
        const maybe_transaction = receiver.receive();
        const transaction = if (maybe_transaction == null) {
            break;
        } else blk: {
            break :blk maybe_transaction.?;
        };

        if (!transaction_batch.contains(transaction.signature)) {
            var pending_transactions_lock = pending_transactions_rw.read();
            defer pending_transactions_lock.unlock();
            const pending_transactions: *const PendingTransactions = pending_transactions_lock.get();

            if (!pending_transactions.contains(transaction.signature)) {
                try transaction_batch.put(transaction.signature, transaction);
            }
        }

        if (transaction_batch.count() >= DEFAULT_BATCH_SIZE or
            (transaction_batch.count() > 0 and
            (try last_batch_sent.elapsed()).asNanos() >= DEFAULT_BATCH_SEND_RATE.asNanos()))
        {
            try sendTransactions(
                allocator,
                service_info_rw,
                transaction_batch.values(),
            );
            last_batch_sent = try Instant.now();

            var pending_transactions_lock = pending_transactions_rw.write();
            defer pending_transactions_lock.unlock();
            var pending_transactions: *PendingTransactions = pending_transactions_lock.mut();

            for (transaction_batch.values()) |_tx| {
                var tx = _tx;
                if (pending_transactions.contains(tx.signature)) continue;
                if (pending_transactions.count() >= MAX_PENDING_POOL_SIZE) break;
                tx.last_sent_time = last_batch_sent;
                try pending_transactions.put(tx.signature, tx);
            }
            transaction_batch.clearRetainingCapacity();
        }
    }
}

fn processTransactionsThread(
    allocator: Allocator,
    service_info_rw: *RwMux(ServiceInfo),
    pending_transactions_rw: *RwMux(PendingTransactions),
    exit: *AtomicBool,
) !void {
    errdefer exit.store(true, .unordered);

    while (!exit.load(.unordered)) {
        std.time.sleep(DEFAULT_PROCESS_TRANSACTIONS_RATE.asNanos());

        var pending_transactions_lock = pending_transactions_rw.write();
        defer pending_transactions_lock.unlock();
        var pending_transactions: *PendingTransactions = pending_transactions_lock.mut();

        if (pending_transactions.count() == 0) continue;

        try processTransactions(
            allocator,
            service_info_rw,
            pending_transactions,
        );
    }
}

fn sendTransactions(
    allocator: Allocator,
    service_info_rw: *RwMux(ServiceInfo),
    transactions: []TransactionInfo,
) !void {
    const leader_addresses = blk: {
        var service_info_lock = service_info_rw.read();
        defer service_info_lock.unlock();
        const service_info: *const ServiceInfo = service_info_lock.get();
        break :blk try service_info.getLeaderAddresses(allocator);
    };
    defer allocator.free(leader_addresses);

    const wire_transactions = try allocator.alloc([]u8, transactions.len);
    defer allocator.free(wire_transactions);

    for (transactions, 0..) |tx, i| {
        wire_transactions[i] = tx.wire_transaction;
    }

    for (leader_addresses) |leader_address| {
        try sendWireTransactions(
            leader_address,
            &wire_transactions,
        );
    }
}

fn sendWireTransactions(
    address: SocketAddr,
    transactions: *const [][]u8,
) !void {
    // TODO: Implement
    // var conn = connection_cache.get_connection(tpu_address);
    // conn.send_data_async(transactions);
    std.debug.print("Sending transactions to {}\n", .{address});
    for (transactions.*, 0..) |tx, i| {
        std.debug.print("Transaction {}: {s}\n", .{ i, tx });
    }
}

fn processTransactions(
    allocator: Allocator,
    service_info_rw: *RwMux(ServiceInfo),
    pending_transactions: *PendingTransactions,
) !void {
    var retry_signatures = std.ArrayList(Signature).init(allocator);
    defer retry_signatures.deinit();

    var drop_signatures = std.ArrayList(Signature).init(allocator);
    defer drop_signatures.deinit();

    var service_info_lock = service_info_rw.write();
    defer service_info_lock.unlock();
    const service_info: *ServiceInfo = service_info_lock.mut();

    const block_height = try service_info.rpc_client.getBlockHeight(allocator);
    const signatures = pending_transactions.keys();
    const signature_statuses = try service_info.rpc_client.getSignatureStatuses(allocator, .{
        .signatures = signatures,
        .searchTransactionHistory = false,
    });

    // Populate retry_signatures and drop_signatures
    var pending_transactions_iter = pending_transactions.iterator();
    for (signature_statuses.value) |maybe_signature_status| {
        const entry = pending_transactions_iter.next().?;
        const signature = entry.key_ptr.*;
        var transaction_info = entry.value_ptr;

        if (maybe_signature_status) |signature_status| {
            // If transaction is rooted, drop it
            if (signature_status.confirmations == null) {
                try drop_signatures.append(signature);
                continue;
            }

            // If transaction failed, drop it
            if (signature_status.err) {
                try drop_signatures.append(signature);
                continue;
            }

            // If transaction last valid block height is less than current block height, drop it
            if (transaction_info.last_valid_block_height < block_height) {
                try drop_signatures.append(signature);
                continue;
            }
        } else {
            // If transaction max retries exceeded, drop it
            const maybe_max_retries = transaction_info.max_retries orelse DEFAULT_MAX_RETRIES;
            if (maybe_max_retries) |max_retries| {
                if (transaction_info.retries >= max_retries) {
                    try drop_signatures.append(signature);
                    continue;
                }
            }

            // If transaction last sent time is greater than the retry sleep time, retry it
            const now = try Instant.now();
            const resend_transaction = if (transaction_info.last_sent_time) |lst| blk: {
                break :blk now.elapsed_since(lst).asNanos() >= DEFAULT_PROCESS_TRANSACTIONS_RATE.asNanos();
            } else true;
            if (resend_transaction) {
                if (transaction_info.last_sent_time) |_| {
                    transaction_info.retries += 1;
                }
                transaction_info.last_sent_time = now;
                try retry_signatures.append(signature);
            }
        }
    }

    // Retry transactions
    if (retry_signatures.items.len > 0) {
        var retry_transactions = try allocator.alloc(TransactionInfo, retry_signatures.items.len);
        defer allocator.free(retry_transactions);

        for (retry_signatures.items, 0..) |signature, i| {
            retry_transactions[i] = pending_transactions.get(signature).?;
        }

        var start_index: usize = 0;
        while (start_index < retry_transactions.len) {
            const end_index = @min(start_index + DEFAULT_BATCH_SIZE, retry_transactions.len);
            const batch = retry_transactions[start_index..end_index];
            try sendTransactions(allocator, service_info_rw, batch);
            start_index = end_index;
        }
    }

    // Remove transactions
    for (drop_signatures.items) |signature| {
        _ = pending_transactions.swapRemove(signature);
    }
}

const ServiceInfo = struct {
    rpc_client: RpcClient,
    epoch_info: RpcEpochInfo,
    epoch_info_instant: Instant,
    latest_blockhash: RpcLatestBlockhash,
    leader_schedule: LeaderSchedule,
    leader_addresses: AutoArrayHashMap(Pubkey, SocketAddr),
    gossip_table_rw: *RwMux(GossipTable),

    const REFERENCE_SLOT_REFRESH_RATE = Duration.fromSecs(60);
    const NUMBER_OF_LEADERS_TO_FORWARD_TO = 2;

    pub fn init(
        allocator: Allocator,
        gossip_table_rw: *RwMux(GossipTable),
    ) !ServiceInfo {
        var rpc_client = RpcClient.init(allocator, "https://api.mainnet-beta.solana.com");

        const epoch_info_instant = try Instant.now();
        const epoch_info = try rpc_client.getEpochInfo(allocator, .{});
        const latest_blockhash = try rpc_client.getLatestBlockhash(allocator, .{});
        const leader_schedule = try fetchLeaderSchedule(allocator, &rpc_client);
        const leader_addresses = try fetchLeaderAddresses(allocator, leader_schedule.slot_leaders, gossip_table_rw);

        return .{
            .rpc_client = rpc_client,
            .epoch_info = epoch_info,
            .epoch_info_instant = epoch_info_instant,
            .latest_blockhash = latest_blockhash,
            .leader_schedule = leader_schedule,
            .leader_addresses = leader_addresses,
            .gossip_table_rw = gossip_table_rw,
        };
    }

    pub fn deinit(self: *ServiceInfo) void {
        self.rpc_client.deinit();
        self.leader_schedule.deinit();
        self.leader_addresses.deinit();
    }

    pub fn refresh(self: *ServiceInfo, allocator: Allocator) !void {
        self.epoch_info_instant = try Instant.now();
        self.epoch_info = try self.rpc_client.getEpochInfo(allocator, .{});
        self.latest_blockhash = try self.rpc_client.getLatestBlockhash(allocator, .{});
        self.leader_schedule = try fetchLeaderSchedule(allocator, &self.rpc_client);
        self.leader_addresses = try fetchLeaderAddresses(allocator, self.leader_schedule.slot_leaders, self.gossip_table_rw);
    }

    pub fn getLeaderAddresses(
        self: *const ServiceInfo,
        allocator: Allocator,
    ) ![]SocketAddr {
        const leaders = try allocator.alloc(Pubkey, NUMBER_OF_LEADERS_TO_FORWARD_TO);
        defer allocator.free(leaders);

        for (0..NUMBER_OF_LEADERS_TO_FORWARD_TO) |i| {
            leaders[i] = try self.getLeaderAfterNSlots(NUM_CONSECUTIVE_LEADER_SLOTS * i);
        }

        const leader_addresses = try allocator.alloc(SocketAddr, NUMBER_OF_LEADERS_TO_FORWARD_TO);
        for (leaders, 0..) |pk, i| {
            leader_addresses[i] = self.leader_addresses.get(pk).?;
        }

        return leader_addresses;
    }

    fn getLeaderAfterNSlots(self: *const ServiceInfo, n: u64) !Pubkey {
        const slots_elapsed = (try self.epoch_info_instant.elapsed()).asMillis() / 400;
        const slot_index = self.epoch_info.slotIndex + slots_elapsed + n;
        std.debug.assert(slot_index < self.leader_schedule.slot_leaders.len);
        return self.leader_schedule.slot_leaders[slot_index];
    }

    fn fetchLeaderSchedule(allocator: Allocator, rpc_client: *RpcClient) !LeaderSchedule {
        const rpc_leader_schedule = try rpc_client.getLeaderSchedule(allocator, .{});

        var num_leaders: u64 = 0;
        for (rpc_leader_schedule.values()) |leader_slots| {
            num_leaders += leader_slots.len;
        }

        const Record = struct {
            slot: Slot,
            key: Pubkey,
        };

        var leaders_index: usize = 0;
        var leaders = try allocator.alloc(Record, num_leaders);
        defer allocator.free(leaders);

        var rpc_leader_iter = rpc_leader_schedule.iterator();
        while (rpc_leader_iter.next()) |entry| {
            const key = try Pubkey.fromString(entry.key_ptr.*);
            for (entry.value_ptr.*) |slot| {
                leaders[leaders_index] = .{
                    .slot = slot,
                    .key = key,
                };
                leaders_index += 1;
            }
        }

        std.mem.sortUnstable(Record, leaders, {}, struct {
            fn gt(_: void, lhs: Record, rhs: Record) bool {
                return switch (std.math.order(lhs.slot, rhs.slot)) {
                    .gt => true,
                    else => false,
                };
            }
        }.gt);

        var leader_pubkeys = try allocator.alloc(Pubkey, leaders.len);
        for (leaders, 0..) |record, i| {
            leader_pubkeys[i] = record.key;
        }

        return LeaderSchedule{
            .allocator = allocator,
            .slot_leaders = leader_pubkeys,
            .start_slot = leaders[0].slot,
        };
    }

    fn fetchLeaderAddresses(allocator: Allocator, leaders: []const Pubkey, gossip_table_rw: *RwMux(GossipTable)) !AutoArrayHashMap(Pubkey, SocketAddr) {
        var gossip_table_lock = gossip_table_rw.read();
        defer gossip_table_lock.unlock();
        const gossip_table: *const GossipTable = gossip_table_lock.get();

        var leader_addresses = AutoArrayHashMap(Pubkey, SocketAddr).init(allocator);
        for (leaders) |leader| {
            if (leader_addresses.contains(leader)) continue;
            const contact_info = gossip_table.getThreadSafeContactInfo(leader);
            if (contact_info == null) continue;
            if (contact_info.?.tpu_addr == null) continue;
            try leader_addresses.put(leader, contact_info.?.tpu_addr.?);
        }

        return leader_addresses;
    }
};

pub const TransactionInfo = struct {
    signature: Signature,
    wire_transaction: []u8,
    last_valid_block_height: u64,
    durable_nonce_info: ?struct { Pubkey, Hash },
    max_retries: ?usize,
    retries: usize,
    last_sent_time: ?Instant,

    pub fn new(
        signature: Signature,
        wire_transaction: []u8,
        last_valid_block_height: u64,
        durable_nonce_info: ?struct { Pubkey, Hash },
        max_retries: ?usize,
    ) TransactionInfo {
        return TransactionInfo{
            .signature = signature,
            .wire_transaction = wire_transaction,
            .last_valid_block_height = last_valid_block_height,
            .durable_nonce_info = durable_nonce_info,
            .max_retries = max_retries,
            .retries = 0,
            .last_sent_time = null,
        };
    }
};

const Transaction = sig.core.transaction.Transaction;
const KeyPair = std.crypto.sign.Ed25519.KeyPair;

pub fn mockTransactionGenerator(
    allocator: Allocator,
    sender: *Channel(TransactionInfo),
    service_info_rw: *RwMux(ServiceInfo),
    exit: *AtomicBool,
) !void {
    errdefer exit.store(true, .unordered);

    const from_pubkey = try Pubkey.fromString("Bkd9xbHF7JgwXmEib6uU3y582WaPWWiasPxzMesiBwWm");
    const from_keypair = KeyPair{
        .public_key = .{ .bytes = from_pubkey.data },
        .secret_key = .{ .bytes = [_]u8{ 76, 196, 192, 17, 40, 245, 120, 49, 64, 133, 213, 227, 12, 42, 183, 70, 235, 64, 235, 96, 246, 205, 78, 13, 173, 111, 254, 96, 210, 208, 121, 240, 159, 193, 185, 89, 227, 77, 234, 91, 232, 234, 253, 119, 162, 105, 200, 227, 123, 90, 111, 105, 72, 53, 60, 147, 76, 154, 44, 72, 29, 165, 2, 246 } },
    };
    const to_pubkey = try Pubkey.fromString("GDFVa3uYXDcNhcNk8A4v28VeF4wcMn8mauZNwVWbpcN");
    const lamports: u64 = 100;

    while (!exit.load(.unordered)) {
        std.time.sleep(Duration.fromSecs(10).asNanos());

        const recent_blockhash = blk: {
            var service_info_lock = service_info_rw.read();
            defer service_info_lock.unlock();
            const service_info: *const ServiceInfo = service_info_lock.get();

            break :blk service_info.latest_blockhash.value.blockhash;
        };

        const transaction = try sig.core.transaction.buildTransferTansaction(
            allocator,
            from_keypair,
            from_pubkey,
            to_pubkey,
            lamports,
            recent_blockhash,
        );

        const transaction_info = TransactionInfo.new(
            transaction.signatures[0],
            try transaction.serialize(allocator),
            0,
            null,
            null,
        );
        std.debug.print("Sending transaction: {any}\n", .{transaction_info.signature});
        try sender.send(transaction_info);
    }
}

test "mockTransaction" {
    const allocator = std.heap.page_allocator;

    var client = RpcClient{
        .http_client = std.http.Client{
            .allocator = std.heap.page_allocator,
        },
        .http_endpoint = "https://api.testnet.solana.com",
    };
    defer client.http_client.deinit();
    const params = sig.rpc.Client.LatestBlockhashParams{};
    const latest_blockhash = try client.getLatestBlockhash(allocator, params);

    const from_pubkey = try Pubkey.fromString("Bkd9xbHF7JgwXmEib6uU3y582WaPWWiasPxzMesiBwWm");
    const from_keypair = KeyPair{
        .public_key = .{ .bytes = from_pubkey.data },
        .secret_key = .{ .bytes = [_]u8{ 76, 196, 192, 17, 40, 245, 120, 49, 64, 133, 213, 227, 12, 42, 183, 70, 235, 64, 235, 96, 246, 205, 78, 13, 173, 111, 254, 96, 210, 208, 121, 240, 159, 193, 185, 89, 227, 77, 234, 91, 232, 234, 253, 119, 162, 105, 200, 227, 123, 90, 111, 105, 72, 53, 60, 147, 76, 154, 44, 72, 29, 165, 2, 246 } },
    };
    const to_pubkey = try Pubkey.fromString("GDFVa3uYXDcNhcNk8A4v28VeF4wcMn8mauZNwVWbpcN");
    const lamports: u64 = 100;

    const transaction = try sig.core.transaction.buildTransferTansaction(
        allocator,
        from_keypair,
        from_pubkey,
        to_pubkey,
        lamports,
        latest_blockhash.value.blockhash,
    );

    _ = transaction;
    // std.debug.print("TRANSACTION\n", .{});
    // for (transaction.signatures) |s| {
    //     std.debug.print("Signature: {s}\n", .{try s.toString()});
    // }

    // std.debug.print("MessageHeader: {}\n", .{transaction.message.header});
    // for (transaction.message.account_keys) |k| {
    //     std.debug.print("AccountKey: {s}\n", .{try k.toString()});
    // }
    // std.debug.print("RecentBlockhash: {any}\n", .{transaction.message.recent_blockhash});
    // for (transaction.message.instructions) |i| {
    //     std.debug.print("Instruction: {any}\n", .{i});
    // }
}
