module sui_wheel::sui_wheel;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::random::{Self, Random};
use sui::sui::SUI;
use sui::table::{Self, Table};

// === Constants ===

const ENotOrganizer: u64 = 0;
const EAlreadySpunMax: u64 = 1;
const EClaimTooEarly: u64 = 2;
const EClaimWindowPassed: u64 = 3;
const ENotWinner: u64 = 4;
const EReclaimTooEarly: u64 = 5;
const ENoEntries: u64 = 6;
const EInsufficientPool: u64 = 7;
const EInvalidEntriesCount: u64 = 8;
const EInvalidPrizes: u64 = 9;
const ENoRemaining: u64 = 10;
const EAlreadyCancelled: u64 = 11;
const EWheelCancelled: u64 = 12;

const MIN_ENTRIES: u64 = 2;
const MAX_ENTRIES: u64 = 200;
const MIN_CLAIM_WINDOW_MS: u64 = 3600000; // 1 hour
const DEFAULT_CLAIM_WINDOW_MS: u64 = 86400000; // 24 hours

// === Structs ===

/// The main structure for the wheel game, managing entries, winners, prizes, and the prize pool.
public struct Wheel has key {
    /// Unique identifier for the wheel object.
    id: UID,
    /// Address of the organizer who created the wheel.
    organizer: address,
    /// List of remaining participant addresses eligible for spinning.
    remaining_entries: vector<address>,
    /// List of winners, each associated with a prize.
    winners: vector<Winner>,
    /// Amounts for each prize, predefined by the organizer.
    prize_amounts: vector<u64>,
    /// Number of spins performed so far.
    spun_count: u64,
    /// Timestamps for each spin.
    spin_times: vector<u64>,
    /// Delay in milliseconds before a winner can claim their prize.
    delay_ms: u64,
    /// Time window in milliseconds for claiming the prize after the delay.
    claim_window_ms: u64,
    /// Balance pool holding the SUI for prizes.
    pool: Balance<SUI>,
    /// Flag indicating if the wheel has been cancelled.
    is_cancelled: bool,
}

/// Structure representing a winner of a prize.
public struct Winner has drop, store {
    /// Address of the winner.
    addr: address,
    /// Index of the prize in the prize_amounts vector.
    prize_index: u64,
    /// Flag indicating if the prize has been claimed.
    claimed: bool,
}

// === Events ===

/// Event emitted when a wheel is created.
public struct CreateEvent has copy, drop {
    // ID of the wheel.
    wheel_id: ID,
    // Address of the organizer.
    organizer: address,
}

/// Event emitted when a spin occurs, announcing the winner and prize index.
public struct SpinEvent has copy, drop {
    /// ID of the wheel.
    wheel_id: ID,
    /// Address of the winner.
    winner: address,
    /// Index of the prize.
    prize_index: u64,
}

/// Event emitted when a prize is claimed.
public struct ClaimEvent has copy, drop {
    /// ID of the wheel.
    wheel_id: ID,
    /// Address of the winner claiming the prize.
    winner: address,
    /// Amount claimed.
    amount: u64,
}

/// Event emitted when the organizer reclaims remaining funds from the pool.
public struct ReclaimEvent has copy, drop {
    /// ID of the wheel.
    wheel_id: ID,
    /// Amount reclaimed.
    amount: u64,
}

// === Accessors ===

/// Returns the organizer address.
public fun organizer(self: &Wheel): address {
    self.organizer
}

/// Returns a reference to the remaining entries.
public fun remaining_entries(self: &Wheel): &vector<address> {
    &self.remaining_entries
}

/// Returns a reference to the prize amounts.
public fun prize_amounts(self: &Wheel): &vector<u64> {
    &self.prize_amounts
}

/// Returns a reference to the winners.
public fun winners(self: &Wheel): &vector<Winner> {
    &self.winners
}

/// Return the address of the winner.
public fun winner_addr(winner: &Winner): address {
    winner.addr
}

/// Returns a reference to the spin times.
public fun spin_times(self: &Wheel): &vector<u64> {
    &self.spin_times
}

/// Returns the delay in milliseconds.
public fun delay_ms(self: &Wheel): u64 {
    self.delay_ms
}

/// Returns the claim window in milliseconds.
public fun claim_window_ms(self: &Wheel): u64 {
    self.claim_window_ms
}

/// Returns the current value of the prize pool.
public fun pool_value(self: &Wheel): u64 {
    balance::value(&self.pool)
}

/// Returns whether the wheel is cancelled.
public fun is_cancelled(self: &Wheel): bool {
    self.is_cancelled
}

/// Returns the number of spins performed.
public fun spun_count(self: &Wheel): u64 {
    self.spun_count
}

/// Returns whether the address has claimed their prize.
public fun claimed(winner: &Winner): bool {
    winner.claimed
}

// === Helper Functions ===

/// Counts the number of unique addresses in the entries vector.
fun count_unique(entries: &vector<address>, ctx: &mut TxContext): u64 {
    let mut unique: Table<address, bool> = table::new(ctx);
    let mut keys: vector<address> = vector::empty();
    let len = vector::length(entries);
    let mut i = 0;
    while (i < len) {
        let addr = *vector::borrow(entries, i);
        if (!table::contains(&unique, addr)) {
            table::add(&mut unique, addr, true);
            vector::push_back(&mut keys, addr);
        };
        i = i + 1;
    };
    let count = vector::length(&keys);
    // Empty the table
    i = 0;
    while (i < vector::length(&keys)) {
        let k = *vector::borrow(&keys, i);
        let _v = table::remove(&mut unique, k);
        i = i + 1;
    };
    table::destroy_empty(unique);
    count
}

/// Shares the Wheel object publicly.
/// This function must be called after creating and optionally mutating the Wheel (e.g., donating to pool)
/// to make it accessible as a shared object.
public fun share_wheel(wheel: Wheel) {
    transfer::share_object(wheel);
}

/// Transfers the optional Coin<SUI> to the recipient if present, or destroys the none option.
/// This helper function allows handling the return value of cancel_wheel_and_reclaim_pool in a PTB without conditionals.
public fun transfer_optional_reclaim(mut opt: Option<Coin<SUI>>, recipient: address) {
    if (option::is_some(&opt)) {
        let coin = option::extract(&mut opt);
        transfer::public_transfer(coin, recipient);
    };
    option::destroy_none(opt);
}

/// Computes the sum of all prize amounts.
fun sum_prize_amounts(prize_amounts: &vector<u64>): u64 {
    let mut total: u64 = 0;
    let mut i = 0;
    let len = vector::length(prize_amounts);
    while (i < len) {
        total = total + *vector::borrow(prize_amounts, i);
        i = i + 1;
    };
    total
}

/// Selects a winner address, either randomly or by popping if only one entry.
/// Removes all duplicates of the winner from remaining_entries if selected randomly.
fun select_winner(
    remaining_entries: &mut vector<address>,
    random: &Random,
    ctx: &mut TxContext,
    num_entries: u64,
): address {
    let winner_addr: address;
    if (num_entries == 1) {
        // Auto-assign if only one entry left
        winner_addr = vector::pop_back(remaining_entries);
    } else {
        let mut generator = random::new_generator(random, ctx);
        let rand_index = generator.generate_u64_in_range(0, num_entries - 1);
        winner_addr = vector::swap_remove(remaining_entries, rand_index);
        // Remove all other entries of this winner_addr
        let mut i = 0;
        while (i < vector::length(remaining_entries)) {
            if (*vector::borrow(remaining_entries, i) == winner_addr) {
                vector::swap_remove(remaining_entries, i);
            } else {
                i = i + 1;
            };
        };
    };
    winner_addr
}

/// Adds the winner to the list, records spin time, increments spun_count, and emits the event.
fun add_winner_and_emit(wheel: &mut Wheel, winner_addr: address, clock: &Clock) {
    let prize_index = wheel.spun_count;
    vector::push_back(
        &mut wheel.winners,
        Winner { addr: winner_addr, prize_index, claimed: false },
    );
    vector::push_back(&mut wheel.spin_times, clock::timestamp_ms(clock));
    wheel.spun_count = wheel.spun_count + 1;
    event::emit(SpinEvent { wheel_id: object::id(wheel), winner: winner_addr, prize_index });
}

/// Validates common preconditions for spin operations
fun validate_spin_preconditions(wheel: &Wheel, ctx: &TxContext) {
    assert!(!wheel.is_cancelled, EWheelCancelled);
    assert!(tx_context::sender(ctx) == wheel.organizer, ENotOrganizer);
    assert!(wheel.spun_count < vector::length(&wheel.prize_amounts), EAlreadySpunMax);
    let num_entries = vector::length(&wheel.remaining_entries);
    assert!(num_entries > 0, ENoEntries);
}

/// Checks if the pool has sufficient funds for all prizes
fun check_pool_sufficiency(wheel: &Wheel) {
    let total_prizes = sum_prize_amounts(&wheel.prize_amounts);
    assert!(balance::value(&wheel.pool) >= total_prizes, EInsufficientPool);
}

/// Validates entry order vector for spin_with_order functions
fun validate_entry_order(entry_order: &vector<u64>, num_entries: u64) {
    assert!(vector::length(entry_order) == num_entries, EInvalidEntriesCount);
    let mut i = 0;
    while (i < vector::length(entry_order)) {
        let idx = *vector::borrow(entry_order, i);
        assert!(idx < num_entries, EInvalidEntriesCount);
        i = i + 1;
    };
}

/// Attempts to auto-assign the last prize if conditions are met
fun try_auto_assign_last_prize(wheel: &mut Wheel, clock: &Clock) {
    let num_prizes = vector::length(&wheel.prize_amounts);
    let num_remaining_entries = vector::length(&wheel.remaining_entries);
    if (wheel.spun_count + 1 == num_prizes && num_remaining_entries == 1) {
        let last_winner_addr = vector::pop_back(&mut wheel.remaining_entries);
        add_winner_and_emit(wheel, last_winner_addr, clock);
    };
}

// === Public Functions ===

/// Creates a new wheel with the given entries, prize amounts, delay, and claim window.
/// Returns the ID of the created wheel.
public fun create_wheel(
    entries: vector<address>,
    prize_amounts: vector<u64>,
    delay_ms: u64,
    claim_window_ms: u64,
    ctx: &mut TxContext,
): Wheel {
    let num_entries = vector::length(&entries);
    let num_prizes = vector::length(&prize_amounts);
    assert!(num_entries >= MIN_ENTRIES && num_entries <= MAX_ENTRIES, EInvalidEntriesCount);
    assert!(num_prizes > 0 && num_entries >= num_prizes, EInvalidPrizes);
    let unique_count = count_unique(&entries, ctx);
    assert!(unique_count >= num_prizes, EInvalidPrizes);
    let claim_window = if (claim_window_ms == 0) {
        DEFAULT_CLAIM_WINDOW_MS
    } else if (claim_window_ms < MIN_CLAIM_WINDOW_MS) {
        MIN_CLAIM_WINDOW_MS
    } else {
        claim_window_ms
    };
    let organizer = tx_context::sender(ctx);
    let wheel = Wheel {
        id: object::new(ctx),
        organizer,
        remaining_entries: entries,
        winners: vector::empty(),
        prize_amounts,
        spun_count: 0,
        spin_times: vector::empty(),
        delay_ms,
        claim_window_ms: claim_window,
        pool: balance::zero(),
        is_cancelled: false,
    };
    event::emit(CreateEvent {
        wheel_id: object::id(&wheel),
        organizer,
    });
    wheel
}

/// Allows the organizer to donate SUI to the wheel's prize pool.
/// No sufficiency check here to allow incremental donations; check happens before spins.
public fun donate_to_pool(wheel: &mut Wheel, coin: Coin<SUI>, ctx: &mut TxContext) {
    assert!(!wheel.is_cancelled, EWheelCancelled);
    assert!(tx_context::sender(ctx) == wheel.organizer, ENotOrganizer);
    balance::join(&mut wheel.pool, coin::into_balance(coin));
    // Note: Removed assert to allow small, incremental donations from organizer.
    // Front-end should monitor pool and ensure sufficiency before allowing spins or updates.
}

/// Updates the remaining_entries if no spins have occurred yet.
public fun update_entries(wheel: &mut Wheel, new_entries: vector<address>, ctx: &mut TxContext) {
    assert!(!wheel.is_cancelled, EWheelCancelled);
    assert!(tx_context::sender(ctx) == wheel.organizer, ENotOrganizer);
    assert!(wheel.spun_count == 0, EAlreadySpunMax); // Only allow before any spins
    let num_entries = vector::length(&new_entries);
    assert!(num_entries >= MIN_ENTRIES && num_entries <= MAX_ENTRIES, EInvalidEntriesCount);
    let num_prizes = vector::length(&wheel.prize_amounts);
    assert!(num_entries >= num_prizes, EInvalidPrizes);
    let unique_count = count_unique(&new_entries, ctx);
    assert!(unique_count >= num_prizes, EInvalidPrizes);
    wheel.remaining_entries = new_entries;
}

/// Updates the prize_amounts if no spins have occurred yet.
/// Also resets winners and spin_times since prizes changed.
public fun update_prize_amounts(
    wheel: &mut Wheel,
    new_prize_amounts: vector<u64>,
    ctx: &mut TxContext,
) {
    assert!(!wheel.is_cancelled, EWheelCancelled);
    assert!(tx_context::sender(ctx) == wheel.organizer, ENotOrganizer);
    assert!(wheel.spun_count == 0, EAlreadySpunMax); // Only allow before any spins
    let num_prizes = vector::length(&new_prize_amounts);
    let num_entries = vector::length(&wheel.remaining_entries);
    assert!(num_prizes > 0 && num_entries >= num_prizes, EInvalidPrizes);
    let unique_count = count_unique(&wheel.remaining_entries, ctx);
    assert!(unique_count >= num_prizes, EInvalidPrizes);
    wheel.prize_amounts = new_prize_amounts;
    wheel.winners = vector::empty();
    wheel.spin_times = vector::empty();
    // Check pool sufficiency after update
    let mut total_prizes: u64 = 0;
    let mut i = 0;
    while (i < vector::length(&wheel.prize_amounts)) {
        total_prizes = total_prizes + *vector::borrow(&wheel.prize_amounts, i);
        i = i + 1;
    };
    assert!(balance::value(&wheel.pool) >= total_prizes, EInsufficientPool);
    // Note: If total prizes increased and pool is insufficient, this will fail; organizer must donate before calling this function.
}

/// Updates the delay_ms if no spins have occurred yet.
public fun update_delay_ms(wheel: &mut Wheel, new_delay_ms: u64, ctx: &mut TxContext) {
    assert!(!wheel.is_cancelled, EWheelCancelled);
    assert!(tx_context::sender(ctx) == wheel.organizer, ENotOrganizer);
    assert!(wheel.spun_count == 0, EAlreadySpunMax); // Only allow before any spins
    wheel.delay_ms = new_delay_ms;
}

/// Updates the claim_window_ms if no spins have occurred yet.
public fun update_claim_window_ms(
    wheel: &mut Wheel,
    new_claim_window_ms: u64,
    ctx: &mut TxContext,
) {
    assert!(!wheel.is_cancelled, EWheelCancelled);
    assert!(tx_context::sender(ctx) == wheel.organizer, ENotOrganizer);
    assert!(wheel.spun_count == 0, EAlreadySpunMax); // Only allow before any spins
    let claim_window = if (new_claim_window_ms == 0) {
        DEFAULT_CLAIM_WINDOW_MS
    } else if (new_claim_window_ms < MIN_CLAIM_WINDOW_MS) {
        MIN_CLAIM_WINDOW_MS
    } else {
        new_claim_window_ms
    };
    wheel.claim_window_ms = claim_window;
}

/// Allows a winner to claim their prize if within the allowed time window.
/// Returns the claimed Coin<SUI>.
public fun claim_prize(wheel: &mut Wheel, clock: &Clock, ctx: &mut TxContext): Coin<SUI> {
    assert!(!wheel.is_cancelled, EWheelCancelled);
    let sender = tx_context::sender(ctx);
    let mut i = 0;
    let mut found = false;
    let mut prize_index = 0;
    while (i < vector::length(&wheel.winners)) {
        let winner = vector::borrow_mut(&mut wheel.winners, i);
        if (winner.addr == sender && !winner.claimed) {
            found = true;
            prize_index = winner.prize_index;
            winner.claimed = true;
            break
        };
        i = i + 1;
    };
    assert!(found, ENotWinner);
    let spin_time = *vector::borrow(&wheel.spin_times, prize_index);
    let current_time = clock::timestamp_ms(clock);
    let deadline = spin_time + wheel.delay_ms + wheel.claim_window_ms;
    assert!(current_time >= spin_time + wheel.delay_ms, EClaimTooEarly);
    assert!(current_time < deadline, EClaimWindowPassed);
    let amount = *vector::borrow(&wheel.prize_amounts, prize_index);
    let reward = balance::split(&mut wheel.pool, amount);
    let coin = coin::from_balance(reward, ctx);
    event::emit(ClaimEvent { wheel_id: object::id(wheel), winner: sender, amount });
    coin
}

/// Allows the organizer to reclaim any remaining funds in the pool after the claim window has passed for all spins.
/// Returns the reclaimed Coin<SUI>.
public fun reclaim_pool(wheel: &mut Wheel, clock: &Clock, ctx: &mut TxContext): Coin<SUI> {
    assert!(!wheel.is_cancelled, EWheelCancelled);
    assert!(tx_context::sender(ctx) == wheel.organizer, ENotOrganizer);
    assert!(wheel.spun_count == vector::length(&wheel.prize_amounts), EAlreadySpunMax);
    let current_time = clock::timestamp_ms(clock);
    let mut max_spin_time = 0;
    let mut i = 0;
    while (i < vector::length(&wheel.spin_times)) {
        let t = *vector::borrow(&wheel.spin_times, i);
        if (t > max_spin_time) { max_spin_time = t; };
        i = i + 1;
    };
    let deadline = max_spin_time + wheel.delay_ms + wheel.claim_window_ms;
    assert!(current_time >= deadline, EReclaimTooEarly);
    let remaining = balance::value(&wheel.pool);
    assert!(remaining > 0, ENoRemaining);
    let reclaim = balance::split(&mut wheel.pool, remaining);
    let coin = coin::from_balance(reclaim, ctx);
    event::emit(ReclaimEvent { wheel_id: object::id(wheel), amount: remaining });
    coin
}

/// Performs a spin on the wheel, selecting a random winner and removing them from future spins.
entry fun spin_wheel(wheel: &mut Wheel, random: &Random, clock: &Clock, ctx: &mut TxContext) {
    validate_spin_preconditions(wheel, ctx);
    check_pool_sufficiency(wheel);

    let num_entries = vector::length(&wheel.remaining_entries);
    let winner_addr = select_winner(&mut wheel.remaining_entries, random, ctx, num_entries);
    add_winner_and_emit(wheel, winner_addr, clock);
}

/// Performs a spin on the wheel, selecting a random winner from a shuffled index order.
entry fun spin_wheel_with_order(
    wheel: &mut Wheel,
    entry_order: vector<u64>, // Shuffled index order
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    validate_spin_preconditions(wheel, ctx);
    check_pool_sufficiency(wheel);

    let num_entries = vector::length(&wheel.remaining_entries);
    validate_entry_order(&entry_order, num_entries);

    // Select winner using shuffled order
    let mut generator = random::new_generator(random, ctx);
    let rand_index = generator.generate_u64_in_range(0, num_entries - 1);
    let shuffled_idx = *vector::borrow(&entry_order, rand_index);
    let winner_addr = *vector::borrow(&wheel.remaining_entries, shuffled_idx);

    // Remove winner from remaining_entries
    vector::swap_remove(&mut wheel.remaining_entries, shuffled_idx);

    add_winner_and_emit(wheel, winner_addr, clock);
}

/// Auto-assigns the last prize if only one entry remains and it's the final spin.
/// Can only be called by organizer.
entry fun auto_assign_last_prize(wheel: &mut Wheel, clock: &Clock, ctx: &TxContext) {
    assert!(!wheel.is_cancelled, EWheelCancelled);
    assert!(tx_context::sender(ctx) == wheel.organizer, ENotOrganizer);
    let num_prizes = vector::length(&wheel.prize_amounts);
    assert!(wheel.spun_count + 1 == num_prizes, EAlreadySpunMax); // Only for last prize
    let num_entries = vector::length(&wheel.remaining_entries);
    assert!(num_entries == 1, ENoEntries); // Must have exactly 1 remaining

    // Auto-assign
    let winner_addr = vector::pop_back(&mut wheel.remaining_entries);
    add_winner_and_emit(wheel, winner_addr, clock);
}

/// Performs a spin on the wheel and, if conditions are met afterward, auto-assigns the last prize in the same transaction.
/// This combines `spin_wheel` and `auto_assign_last_prize` for efficiency when the front-end detects that the next spin
/// will leave one entry and one prize remaining.
entry fun spin_wheel_and_assign_last_prize(
    wheel: &mut Wheel,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    validate_spin_preconditions(wheel, ctx);
    check_pool_sufficiency(wheel);

    let num_entries = vector::length(&wheel.remaining_entries);
    let winner_addr = select_winner(&mut wheel.remaining_entries, random, ctx, num_entries);
    add_winner_and_emit(wheel, winner_addr, clock);

    // Try to auto-assign the last prize if conditions are met
    try_auto_assign_last_prize(wheel, clock);
}

/// Performs a spin on the wheel, selecting a random winner from a shuffled index order, and auto-assigns the last prize in the same transaction.
entry fun spin_wheel_and_assign_last_prize_with_order(
    wheel: &mut Wheel,
    entry_order: vector<u64>, // Shuffled index order
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    validate_spin_preconditions(wheel, ctx);
    check_pool_sufficiency(wheel);

    let num_entries = vector::length(&wheel.remaining_entries);
    validate_entry_order(&entry_order, num_entries);

    // Select winner based on shuffled order
    let mut generator = random::new_generator(random, ctx);
    let rand_index = generator.generate_u64_in_range(0, num_entries - 1);
    let shuffled_idx = *vector::borrow(&entry_order, rand_index);
    let winner_addr = *vector::borrow(&wheel.remaining_entries, shuffled_idx);

    // Remove winner from entries
    vector::swap_remove(&mut wheel.remaining_entries, shuffled_idx);

    // Add and emit
    add_winner_and_emit(wheel, winner_addr, clock);

    // Try to auto-assign the last prize if conditions are met
    try_auto_assign_last_prize(wheel, clock);
}

/// Cancels the wheel if no spins have occurred, reclaims the pool, and deactivates it.
/// Returns the reclaimed Coin<SUI> if pool has balance.
public fun cancel_wheel_and_reclaim_pool(
    wheel: &mut Wheel,
    ctx: &mut TxContext,
): Option<Coin<SUI>> {
    assert!(tx_context::sender(ctx) == wheel.organizer, ENotOrganizer);
    assert!(wheel.spun_count == 0, EAlreadySpunMax); // Only allow before any spins
    assert!(!wheel.is_cancelled, EAlreadyCancelled);

    wheel.is_cancelled = true;
    let remaining = balance::value(&wheel.pool);
    if (remaining > 0) {
        let reclaim = balance::split(&mut wheel.pool, remaining);
        option::some(coin::from_balance(reclaim, ctx))
    } else {
        option::none()
    }
}
