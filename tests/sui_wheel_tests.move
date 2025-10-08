#[test_only]
module sui_wheel::sui_wheel_tests;

#[test_only]
use sui::balance;
#[test_only]
use sui::coin;
#[test_only]
use sui::sui::SUI;
#[test_only]
use sui::test_scenario::{Self, Scenario};
#[test_only]
use sui_wheel::sui_wheel::{Self, Wheel, create_wheel, share_wheel};
#[test_only]
use sui::clock::{Self, Clock};
#[test_only]
use sui::random::{Self, update_randomness_state_for_testing, Random};

// === Helpers ===
// Helper to setup clock in tests
fun setup_clock(scenario: &mut Scenario): Clock {
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(50); // Or any initial time
    clock
}

// === Tests ===
#[test]
fun test_create_wheel_success() {
    let mut scenario = test_scenario::begin(@0xCAFE);
    let entries = vector[@0xA, @0xB, @0xC];
    let prize_amounts = vector[1000, 500, 200];
    let delay_ms = 3600000;
    let claim_window_ms = 86400000;

    let wheel = create_wheel(entries, prize_amounts, delay_ms, claim_window_ms, scenario.ctx());
    share_wheel(wheel);

    scenario.next_tx(@0xCAFE);
    let wheel: Wheel = scenario.take_shared<Wheel>();

    assert!(sui_wheel::organizer(&wheel) == @0xCAFE, 0);
    assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 3, 0);
    assert!(vector::length(sui_wheel::prize_amounts(&wheel)) == 3, 0);
    assert!(sui_wheel::delay_ms(&wheel) == delay_ms, 0);
    assert!(sui_wheel::claim_window_ms(&wheel) == claim_window_ms, 0);
    assert!(sui_wheel::pool_value(&wheel) == 0, 0);
    assert!(!sui_wheel::is_cancelled(&wheel), 0);

    test_scenario::return_shared(wheel);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = sui_wheel::EInvalidEntriesCount)]
fun test_create_wheel_invalid_entries_min() {
    let mut scenario = test_scenario::begin(@0xCAFE);
    let ctx = scenario.ctx();
    let entries = vector[@0xA];
    let prize_amounts = vector[1000];

    let _wheel = create_wheel(entries, prize_amounts, 0, 0, ctx); //fail here
    abort 1337
}

#[test]
#[expected_failure(abort_code = sui_wheel::EInvalidPrizes)]
fun test_create_wheel_invalid_prizes_entries_less_than_prizes() {
    let mut scenario = test_scenario::begin(@0xCAFE);
    let ctx = scenario.ctx();
    let entries = vector[@0xA, @0xB];
    let prize_amounts = vector[1000, 500, 300];

    let _wheel = create_wheel(entries, prize_amounts, 0, 0, ctx);
    abort 1337
}

#[test]
fun test_donate_to_pool_success() {
    let organizer = @0xCAFE;
    let mut scenario = test_scenario::begin(organizer);
    let entries = vector[@0xA, @0xB];
    let prize_amounts = vector[500];

    // Create wheel
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let wheel = create_wheel(entries, prize_amounts, 0, 0, ctx);
        share_wheel(wheel);
    };

    // Donate to pool
    scenario.next_tx(organizer);
    {
        let mut wheel = test_scenario::take_shared<Wheel>(&scenario);
        let donate_amount: u64 = 2000;
        let balance = balance::create_for_testing<SUI>(donate_amount);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == donate_amount, 0);
        test_scenario::return_shared(wheel);
    };
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = sui_wheel::EWheelCancelled)]
fun test_donate_to_pool_cancelled() {
    let organizer = @0xCAFE;
    let mut scenario = test_scenario::begin(organizer);

    // Create wheel
    let entries = vector[@0x1, @0x2];
    {
        let prize_amounts = vector[10000];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Cancel wheel
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let reclaim_opt = sui_wheel::cancel_wheel_and_reclaim_pool(&mut wheel, scenario.ctx());
        if (option::is_some(&reclaim_opt)) {
            let reclaim_coin = option::destroy_some(reclaim_opt);
            coin::destroy_zero(reclaim_coin);
        } else {
            option::destroy_none(reclaim_opt);
        };
        test_scenario::return_shared(wheel);
    };

    // Donate to pool
    // This should fail because the wheel is cancelled
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let donate_amount: u64 = 2000;
        let balance = balance::create_for_testing<SUI>(donate_amount);
        let coin = coin::from_balance(balance, scenario.ctx());
        // fail here
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        test_scenario::return_shared(wheel);
    };
    scenario.end();
}

#[test]
fun test_update_entries_and_prize_amounts_with_donate() {
    let organizer = @0xCAFE;
    let mut scenario = test_scenario::begin(organizer);
    let entries = vector[@0xA, @0xB];
    let prize_amounts = vector[1000];

    // First transaction: Create wheel
    let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
    share_wheel(wheel);

    // Second transaction: Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1000;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == initial_donate, 0);
        test_scenario::return_shared(wheel);
    };

    // Third transaction: Donate additional, update entries and prizes
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        // Additional donate for new prizes
        let additional_donate: u64 = 1500; // For new total 2500
        let balance = balance::create_for_testing<SUI>(additional_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());

        // Update entries (new entries with more)
        let new_entries = vector[@0x1, @0x2, @0x3];
        sui_wheel::update_entries(&mut wheel, new_entries, scenario.ctx());
        // Update prizes (new prizes requiring more pool)
        let new_prize_amounts = vector[1000u64, 500u64, 1000u64]; // Total 2500
        sui_wheel::update_prize_amounts(&mut wheel, new_prize_amounts, scenario.ctx());

        // Verify
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 3, 1);
        assert!(vector::length(sui_wheel::prize_amounts(&wheel)) == 3, 2);
        assert!(sui_wheel::pool_value(&wheel) == 2500, 3);
        test_scenario::return_shared(wheel);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::ENotOrganizer)]
fun test_update_entries_not_organizer() {
    let mut scenario = test_scenario::begin(@0xCAFE);
    let ctx = scenario.ctx();
    let entries = vector[@0xA, @0xB];
    let prize_amounts = vector[1000];

    let wheel = create_wheel(entries, prize_amounts, 0, 0, ctx);
    share_wheel(wheel);

    scenario.next_tx(@0xA);
    let mut wheel = scenario.take_shared<Wheel>();

    // fail here
    sui_wheel::update_entries(&mut wheel, vector[@0x1], scenario.ctx());

    test_scenario::return_shared(wheel);
    scenario.end();
}

#[test]
fun test_update_prize_amounts_success() {
    let organizer = @0xCAFE;
    let mut scenario = test_scenario::begin(organizer);
    let entries = vector[@0xA, @0xB, @0xC];
    let prize_amounts = vector[1000, 200];

    let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
    share_wheel(wheel);

    // donate to pool
    scenario.next_tx(organizer);
    let mut wheel: Wheel = scenario.take_shared<Wheel>();
    let coin = coin::mint_for_testing<SUI>(1500, scenario.ctx());
    sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());

    // only update prize amounts
    let new_prize_amounts = vector[1000, 400];
    sui_wheel::update_prize_amounts(&mut wheel, new_prize_amounts, scenario.ctx());
    assert!(vector::length(sui_wheel::prize_amounts(&wheel)) == 2, 0);
    assert!(vector::length(sui_wheel::winners(&wheel)) == 0, 0);
    assert!(vector::length(sui_wheel::spin_times(&wheel)) == 0, 0);

    test_scenario::return_shared(wheel);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::EInsufficientPool)]
fun test_update_prize_amounts_insufficient_pool() {
    let mut scenario = test_scenario::begin(@0xCAFE);
    {
        let entries = vector[@0xA, @0xB];
        let prize_amounts = vector[1000];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    scenario.next_tx(@0xCAFE);
    // skip donate to pool
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let new_prize_amounts = vector[2000];
        // fail here
        sui_wheel::update_prize_amounts(&mut wheel, new_prize_amounts, scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::EAlreadySpunMax)]
fun test_update_entries_after_spin() {
    let admin = @0x0;
    let organizer = @0xCAFE;
    let mut scenario = test_scenario::begin(organizer);

    let entries = vector[@0xA, @0xB];
    let prize_amounts = vector[1000];
    let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
    share_wheel(wheel);

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1000;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == initial_donate, 0);
        test_scenario::return_shared(wheel);
    };

    // Setup randomness in a separate tx to create the Random object
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    // Now in a new tx, take and update the Random object (must be after creation tx)
    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F",
        scenario.ctx(),
    );

    // Spin
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        // Perform the spin to reach max spun_count (1 prize, so 1 spin)
        let clock = setup_clock(&mut scenario);
        sui_wheel::spin_wheel(&mut wheel, &random_state, &clock, scenario.ctx());
        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);

    // Attempt update_entries, which should fail (EAlreadySpunMax)
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        sui_wheel::update_entries(&mut wheel, vector[@0xC, @0xD], scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    scenario.end();
}

#[test]
fun test_2_spins_success() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB, @0xC];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == initial_donate, 0);
        test_scenario::return_shared(wheel);
    };

    // Setup randomness in a separate tx to create the Random object
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    // Now in a new tx, take and update the Random object (must be after creation tx)
    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Spin 1 time
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        sui_wheel::spin_wheel(&mut wheel, &random_state, &clock, scenario.ctx());

        assert!(sui_wheel::spun_count(&wheel) == 1, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 1, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) <= 2, 0);

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    // Spin 2 times
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        sui_wheel::spin_wheel(&mut wheel, &random_state, &clock, scenario.ctx());

        assert!(sui_wheel::spun_count(&wheel) == 2, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 2, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) <= 1, 0);

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
fun test_spin_and_auto_assign() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 2 unique entries and 2 prizes
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == initial_donate, 0);
        test_scenario::return_shared(wheel);
    };

    // Setup randomness in a separate tx to create the Random object
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    // Now in a new tx, take and update the Random object (must be after creation tx)
    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Spin 1 time using spin_wheel
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        sui_wheel::spin_wheel(&mut wheel, &random_state, &clock, scenario.ctx());

        assert!(sui_wheel::spun_count(&wheel) == 1, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 1, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 1, 0); // After removing one unique winner

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    // Auto-assign the last prize
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        sui_wheel::auto_assign_last_prize(&mut wheel, &clock, scenario.ctx());

        assert!(sui_wheel::spun_count(&wheel) == 2, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 2, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 0, 0);

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
fun test_spin_wheel_and_assign_last_prize() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 2 unique entries and 2 prizes
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == initial_donate, 0);
        test_scenario::return_shared(wheel);
    };

    // Setup randomness in a separate tx to create the Random object
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    // Now in a new tx, take and update the Random object (must be after creation tx)
    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Perform combined spin and auto-assign in one transaction
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        sui_wheel::spin_wheel_and_assign_last_prize(
            &mut wheel,
            &random_state,
            &clock,
            scenario.ctx(),
        );

        // Verify final state after both actions
        assert!(sui_wheel::spun_count(&wheel) == 2, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 2, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 0, 0);

        // Optional: Check that winners are different addresses
        let winners_vec = sui_wheel::winners(&wheel);
        let winner1 = vector::borrow(winners_vec, 0);
        let winner2 = vector::borrow(winners_vec, 1);
        assert!(sui_wheel::winner_addr(winner1) != sui_wheel::winner_addr(winner2), 0);

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
fun test_duplicate_pairs() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 4 entries: two pairs of duplicates (A,A,B,B)
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xA, @0xB, @0xB];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == initial_donate, 0);
        test_scenario::return_shared(wheel);
    };

    // Setup randomness in a separate tx to create the Random object
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    // Now in a new tx, take and update the Random object (must be after creation tx)
    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Perform combined spin and auto-assign
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        sui_wheel::spin_wheel_and_assign_last_prize(
            &mut wheel,
            &random_state,
            &clock,
            scenario.ctx(),
        );
        assert!(sui_wheel::spun_count(&wheel) == 2, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 2, 0);
        // After spin and auto-assign, remaining should be 0
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 0, 0);

        // Optional: Check that winners are different addresses
        let winners_vec = sui_wheel::winners(&wheel);
        let winner1 = vector::borrow(winners_vec, 0);
        let winner2 = vector::borrow(winners_vec, 1);
        assert!(sui_wheel::winner_addr(winner1) != sui_wheel::winner_addr(winner2), 0);

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::EInsufficientPool)]
fun test_spin_wheel_insufficient_pool() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB, @0xC];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount, not enough to spin
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1000;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == initial_donate, 0);
        test_scenario::return_shared(wheel);
    };

    // Setup randomness in a separate tx to create the Random object
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    // Now in a new tx, take and update the Random object (must be after creation tx)
    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F",
        scenario.ctx(),
    );

    // Spin
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);

        // fail here
        sui_wheel::spin_wheel(&mut wheel, &random_state, &clock, scenario.ctx());

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
fun test_claim_prize_success() {
    let admin = @0x0;
    let organizer = @0xCAFE;
    let winner_addr = @0xA;

    let mut scenario = test_scenario::begin(organizer);

    // Create wheel with 1 prize
    let entries = vector[@0xA, @0xB];
    let prize_amounts = vector[1000];
    let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
    share_wheel(wheel);

    // Donate to pool
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let donate_balance = balance::create_for_testing<SUI>(1000);
    let donate_coin = coin::from_balance(donate_balance, scenario.ctx());
    sui_wheel::donate_to_pool(&mut wheel, donate_coin, scenario.ctx());
    assert!(sui_wheel::pool_value(&wheel) == 1000, 0);
    test_scenario::return_shared(wheel);

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F",
        scenario.ctx(),
    );

    // Setup clock as shared for reuse across tx
    scenario.next_tx(admin);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000); // Initial timestamp
    clock.share_for_testing();

    // Perform spin (assume deterministic winner based on seed; adjust entries/seed if needed to ensure @0xA wins)
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let clock_shared = scenario.take_shared<Clock>();
    sui_wheel::spin_wheel(&mut wheel, &random_state, &clock_shared, scenario.ctx());
    assert!(sui_wheel::spun_count(&wheel) == 1, 1);

    // Assert winner is @0xA (based on fixed seed and entries order; test may need adjustment if different winner)
    let winners = sui_wheel::winners(&wheel);
    let winner = vector::borrow(winners, 0);
    assert!(sui_wheel::winner_addr(winner) == winner_addr, 2);
    test_scenario::return_shared(wheel);
    test_scenario::return_shared(clock_shared);

    // Claim prize as winner (time within window: after delay=0, before spin_time + window)
    scenario.next_tx(winner_addr);
    let mut wheel = scenario.take_shared<Wheel>();
    let clock_shared = scenario.take_shared<Clock>();
    let prize_coin = sui_wheel::claim_prize(&mut wheel, &clock_shared, scenario.ctx());
    assert!(coin::value(&prize_coin) == 1000, 3);
    let winners = sui_wheel::winners(&wheel);
    let winner = vector::borrow(winners, 0);
    assert!(sui_wheel::claimed(winner), 4);
    assert!(sui_wheel::pool_value(&wheel) == 0, 5);
    // Destroy prize coin for test cleanup
    let prize_balance = coin::into_balance(prize_coin);
    balance::destroy_for_testing(prize_balance);
    test_scenario::return_shared(wheel);
    test_scenario::return_shared(clock_shared);

    // Cleanup
    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::EClaimTooEarly)]
fun test_claim_prize_too_early() {
    let admin = @0x0;
    let organizer = @0xCAFE;
    let winner_addr = @0xA;

    let mut scenario = test_scenario::begin(organizer);

    // Create wheel with delay_ms > 0
    let entries = vector[@0xA, @0xB];
    let prize_amounts = vector[1000];
    let wheel = create_wheel(entries, prize_amounts, 1000, 86400000, scenario.ctx()); // the user only claim after 86400000 + 1000 = 86401000
    share_wheel(wheel);

    // Donate to pool
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let donate_balance = balance::create_for_testing<SUI>(1000);
    let donate_coin = coin::from_balance(donate_balance, scenario.ctx());
    sui_wheel::donate_to_pool(&mut wheel, donate_coin, scenario.ctx());
    assert!(sui_wheel::pool_value(&wheel) == 1000, 0);
    test_scenario::return_shared(wheel);

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F",
        scenario.ctx(),
    );

    // Setup clock for spin
    scenario.next_tx(admin);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(86400000); // Initial timestamp
    clock.share_for_testing();

    // Perform spin (spin_time will be 1000)
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let clock_shared = scenario.take_shared<Clock>();
    sui_wheel::spin_wheel(&mut wheel, &random_state, &clock_shared, scenario.ctx());
    test_scenario::return_shared(wheel);
    test_scenario::return_shared(clock_shared);

    // Setup clock for claim
    scenario.next_tx(admin);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(86400999); // the user claim at 86400999 (86401000 - 86400999 = 1ms, need to wait more than 1ms to claim)
    clock.share_for_testing();

    scenario.next_tx(winner_addr);
    let mut wheel = scenario.take_shared<Wheel>();
    let clock_shared = scenario.take_shared<Clock>();
    let _prize_coin = sui_wheel::claim_prize(&mut wheel, &clock_shared, scenario.ctx()); // Should abort here
    abort 1337
}

#[test]
fun test_reclaim_pool_success() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    let mut scenario = test_scenario::begin(organizer);

    // Create wheel with 1 prize, set delay and claim window for testing
    let entries = vector[@0xA, @0xB];
    let prize_amounts = vector[1000];
    let delay_ms: u64 = 3600000; // 1 hour
    let claim_window_ms: u64 = 86400000; // 24 hours
    let wheel = create_wheel(entries, prize_amounts, delay_ms, claim_window_ms, scenario.ctx());
    share_wheel(wheel);

    // Donate to pool
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let donate_balance = balance::create_for_testing<SUI>(1000);
    let donate_coin = coin::from_balance(donate_balance, scenario.ctx());
    sui_wheel::donate_to_pool(&mut wheel, donate_coin, scenario.ctx());
    assert!(sui_wheel::pool_value(&wheel) == 1000, 0);
    test_scenario::return_shared(wheel);

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F",
        scenario.ctx(),
    );

    // Setup clock as shared for reuse across tx
    scenario.next_tx(admin);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(3600000); // Initial timestamp
    clock.share_for_testing();

    // Perform spin
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let clock_shared = scenario.take_shared<Clock>();
    sui_wheel::spin_wheel(&mut wheel, &random_state, &clock_shared, scenario.ctx());
    assert!(sui_wheel::spun_count(&wheel) == 1, 1);
    test_scenario::return_shared(wheel);
    test_scenario::return_shared(clock_shared);

    // Advance clock to after claim window (deadline = spin_time 1000 + delay 1000 + window 2000 = 4000)
    scenario.next_tx(admin);
    let mut clock_shared = scenario.take_shared<Clock>();
    clock_shared.set_for_testing(3600000 + delay_ms + claim_window_ms);
    test_scenario::return_shared(clock_shared);

    // Reclaim pool as organizer (should succeed, reclaim 1000 since unclaimed)
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let clock_shared = scenario.take_shared<Clock>();
    let reclaimed_coin = sui_wheel::reclaim_pool(&mut wheel, &clock_shared, scenario.ctx());
    assert!(coin::value(&reclaimed_coin) == 1000, 2);
    assert!(sui_wheel::pool_value(&wheel) == 0, 3);
    // Destroy reclaimed coin for test cleanup
    let reclaimed_balance = coin::into_balance(reclaimed_coin);
    balance::destroy_for_testing(reclaimed_balance);
    test_scenario::return_shared(wheel);
    test_scenario::return_shared(clock_shared);

    // Cleanup
    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
fun test_cancel_wheel_success() {
    let organizer = @0xCAFE;

    let mut scenario = test_scenario::begin(organizer);

    // Create wheel
    let entries = vector[@0xA, @0xB];
    let prize_amounts = vector[1000];
    let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
    share_wheel(wheel);

    // Donate to pool
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let donate_balance = balance::create_for_testing<SUI>(1000);
    let donate_coin = coin::from_balance(donate_balance, scenario.ctx());
    sui_wheel::donate_to_pool(&mut wheel, donate_coin, scenario.ctx());
    assert!(sui_wheel::pool_value(&wheel) == 1000, 0);
    test_scenario::return_shared(wheel);

    // Cancel wheel and reclaim (before any spins)
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let reclaimed_opt = sui_wheel::cancel_wheel_and_reclaim_pool(&mut wheel, scenario.ctx());
    assert!(sui_wheel::is_cancelled(&wheel), 1);
    assert!(sui_wheel::pool_value(&wheel) == 0, 2);
    assert!(option::is_some(&reclaimed_opt), 3);
    let reclaimed_coin = option::destroy_some(reclaimed_opt);
    assert!(coin::value(&reclaimed_coin) == 1000, 4);
    // Destroy reclaimed coin for test cleanup
    let reclaimed_balance = coin::into_balance(reclaimed_coin);
    balance::destroy_for_testing(reclaimed_balance);
    test_scenario::return_shared(wheel);

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::EAlreadySpunMax)]
fun test_cancel_wheel_after_spin() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    let mut scenario = test_scenario::begin(organizer);

    // Create wheel
    let entries = vector[@0xA, @0xB];
    let prize_amounts = vector[1000];
    let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
    share_wheel(wheel);

    // Donate to pool
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let donate_balance = balance::create_for_testing<SUI>(1000);
    let donate_coin = coin::from_balance(donate_balance, scenario.ctx());
    sui_wheel::donate_to_pool(&mut wheel, donate_coin, scenario.ctx());
    assert!(sui_wheel::pool_value(&wheel) == 1000, 0);
    test_scenario::return_shared(wheel);

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F",
        scenario.ctx(),
    );

    // Setup clock as shared for reuse across tx
    scenario.next_tx(admin);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000); // Initial timestamp
    clock.share_for_testing();

    // Perform spin (spun_count becomes 1)
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let clock_shared = scenario.take_shared<Clock>();
    sui_wheel::spin_wheel(&mut wheel, &random_state, &clock_shared, scenario.ctx());
    assert!(sui_wheel::spun_count(&wheel) == 1, 1);
    test_scenario::return_shared(wheel);
    test_scenario::return_shared(clock_shared);

    // Attempt cancel after spin (should fail with EAlreadySpunMax)
    scenario.next_tx(organizer);
    let mut wheel = scenario.take_shared<Wheel>();
    let _reclaimed_opt = sui_wheel::cancel_wheel_and_reclaim_pool(&mut wheel, scenario.ctx()); // Aborts here
    abort 1337
}

#[test]
fun test_spin_wheel_with_order_success() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 3 entries and 2 prizes
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB, @0xC];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == initial_donate, 0);
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Spin with custom order [2, 0, 1] (shuffled index order)
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[2u64, 0u64, 1u64]; // Shuffled index order
        sui_wheel::spin_wheel_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );

        assert!(sui_wheel::spun_count(&wheel) == 1, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 1, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 2, 0);

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::EInvalidEntriesCount)]
fun test_spin_wheel_with_order_invalid_order_length() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 3 entries and 1 prize
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB, @0xC];
        let prize_amounts = vector[1000];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1000;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Spin with invalid order length (should be 3, but provided 2)
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[0u64, 1u64]; // Wrong length - should be 3 elements
        sui_wheel::spin_wheel_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::EInvalidEntriesCount)]
fun test_spin_wheel_with_order_invalid_index() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 3 entries and 1 prize
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB, @0xC];
        let prize_amounts = vector[1000];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1000;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Spin with invalid index (3 is out of bounds for 3 entries)
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[0u64, 1u64, 3u64]; // Invalid index 3
        sui_wheel::spin_wheel_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::ENotOrganizer)]
fun test_spin_wheel_with_order_not_organizer() {
    let admin = @0x0;
    let organizer = @0xCAFE;
    let non_organizer = @0xBEEF;

    // Create wheel
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB, @0xC];
        let prize_amounts = vector[1000];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1000;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Non-organizer tries to spin
    scenario.next_tx(non_organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[0u64, 1u64, 2u64];
        sui_wheel::spin_wheel_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
fun test_spin_wheel_with_order_deterministic_selection() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 3 entries and 1 prize
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB, @0xC];
        let prize_amounts = vector[1000];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1000;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    // Setup randomness with fixed seed
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"0000000000000000000000000000000000000000000000000000000000000000", // Fixed seed
        scenario.ctx(),
    );

    // Spin with specific order [1, 0, 2] - should select index 1 from this order
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[1u64, 0u64, 2u64]; // Shuffled order
        sui_wheel::spin_wheel_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );

        assert!(sui_wheel::spun_count(&wheel) == 1, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 1, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 2, 0);

        // Verify the winner is removed from remaining entries
        let remaining = sui_wheel::remaining_entries(&wheel);
        let winner = vector::borrow(sui_wheel::winners(&wheel), 0);
        let winner_addr = sui_wheel::winner_addr(winner);

        // Check that winner is not in remaining entries
        let mut found = false;
        let mut i = 0;
        while (i < vector::length(remaining)) {
            if (*vector::borrow(remaining, i) == winner_addr) {
                found = true;
                break
            };
            i = i + 1;
        };
        assert!(!found, 1); // Winner should not be in remaining entries

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
fun test_spin_wheel_and_assign_last_prize_with_order_success() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 2 unique entries and 2 prizes
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == initial_donate, 0);
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Perform combined spin and auto-assign with custom order [1, 0]
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[1u64, 0u64]; // Shuffled order
        sui_wheel::spin_wheel_and_assign_last_prize_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );

        // Verify final state after both actions
        assert!(sui_wheel::spun_count(&wheel) == 2, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 2, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 0, 0);

        // Verify that winners are different addresses
        let winners_vec = sui_wheel::winners(&wheel);
        let winner1 = vector::borrow(winners_vec, 0);
        let winner2 = vector::borrow(winners_vec, 1);
        assert!(sui_wheel::winner_addr(winner1) != sui_wheel::winner_addr(winner2), 1);

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
fun test_spin_wheel_and_assign_last_prize_with_order_duplicate_pairs() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 4 entries: two pairs of duplicates (A,A,B,B) and 2 prizes
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xA, @0xB, @0xB];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        assert!(sui_wheel::pool_value(&wheel) == initial_donate, 0);
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Perform combined spin and auto-assign with custom order [3, 0, 1, 2]
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[3u64, 0u64, 1u64, 2u64]; // Shuffled order
        sui_wheel::spin_wheel_and_assign_last_prize_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );

        // Verify final state after both actions
        assert!(sui_wheel::spun_count(&wheel) == 2, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 2, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 0, 0);

        // Verify that winners are different addresses
        let winners_vec = sui_wheel::winners(&wheel);
        let winner1 = vector::borrow(winners_vec, 0);
        let winner2 = vector::borrow(winners_vec, 1);
        assert!(sui_wheel::winner_addr(winner1) != sui_wheel::winner_addr(winner2), 1);

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::EInvalidEntriesCount)]
fun test_spin_wheel_and_assign_last_prize_with_order_invalid_length() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 2 entries and 2 prizes
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Spin with invalid order length (should be 2, but provided 1)
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[0u64]; // Wrong length - should be 2 elements
        sui_wheel::spin_wheel_and_assign_last_prize_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::EInvalidEntriesCount)]
fun test_spin_wheel_and_assign_last_prize_with_order_invalid_index() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 2 entries and 2 prizes
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Spin with invalid index (2 is out of bounds for 2 entries)
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[0u64, 2u64]; // Invalid index 2
        sui_wheel::spin_wheel_and_assign_last_prize_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui_wheel::ENotOrganizer)]
fun test_spin_wheel_and_assign_last_prize_with_order_not_organizer() {
    let admin = @0x0;
    let organizer = @0xCAFE;
    let non_organizer = @0xBEEF;

    // Create wheel
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Non-organizer tries to spin
    scenario.next_tx(non_organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[0u64, 1u64];
        sui_wheel::spin_wheel_and_assign_last_prize_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
fun test_spin_wheel_and_assign_last_prize_with_order_no_auto_assign() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 3 entries and 1 prize (no auto-assign should happen)
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xB, @0xC];
        let prize_amounts = vector[1000];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1000;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Spin with custom order [2, 0, 1] - should only spin once (no auto-assign)
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[2u64, 0u64, 1u64]; // Shuffled order
        sui_wheel::spin_wheel_and_assign_last_prize_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );

        // Verify only one spin occurred (no auto-assign)
        assert!(sui_wheel::spun_count(&wheel) == 1, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 1, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 2, 0);

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}

#[test]
fun test_spin_wheel_and_assign_last_prize_with_order_duplicate_entries() {
    let admin = @0x0;
    let organizer = @0xCAFE;

    // Create wheel with 4 entries: two pairs of duplicates (A,A,B,B) and 2 prizes
    let mut scenario = test_scenario::begin(organizer);
    {
        let entries = vector[@0xA, @0xA, @0xB, @0xB];
        let prize_amounts = vector[1000, 500];
        let wheel = create_wheel(entries, prize_amounts, 0, 0, scenario.ctx());
        share_wheel(wheel);
    };

    // Donate initial amount
    scenario.next_tx(organizer);
    {
        let initial_donate: u64 = 1500;
        let mut wheel = scenario.take_shared<Wheel>();
        let balance = balance::create_for_testing<SUI>(initial_donate);
        let coin = coin::from_balance(balance, scenario.ctx());
        sui_wheel::donate_to_pool(&mut wheel, coin, scenario.ctx());
        test_scenario::return_shared(wheel);
    };

    // Setup randomness
    scenario.next_tx(admin);
    random::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let mut random_state = scenario.take_shared<Random>();
    random_state.update_randomness_state_for_testing(
        0,
        x"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567",
        scenario.ctx(),
    );

    // Spin with custom order [3, 0, 1, 2] - should spin and auto-assign since after spin unique==1 for last prize
    scenario.next_tx(organizer);
    {
        let mut wheel = scenario.take_shared<Wheel>();
        let clock = setup_clock(&mut scenario);
        let entry_order = vector[3u64, 0u64, 1u64, 2u64]; // Shuffled order
        sui_wheel::spin_wheel_and_assign_last_prize_with_order(
            &mut wheel,
            entry_order,
            &random_state,
            &clock,
            scenario.ctx(),
        );

        // Verify spin and auto-assign occurred
        assert!(sui_wheel::spun_count(&wheel) == 2, 0);
        assert!(vector::length(sui_wheel::winners(&wheel)) == 2, 0);
        assert!(vector::length(sui_wheel::remaining_entries(&wheel)) == 0, 0);

        // Additional checks: winners should be different addresses
        let winners_vec = sui_wheel::winners(&wheel);
        let winner1 = vector::borrow(winners_vec, 0);
        let winner2 = vector::borrow(winners_vec, 1);
        assert!(sui_wheel::winner_addr(winner1) != sui_wheel::winner_addr(winner2), 1);

        test_scenario::return_shared(wheel);
        clock.destroy_for_testing();
    };

    scenario.next_tx(admin);
    test_scenario::return_shared(random_state);
    scenario.end();
}
