module gay::staking {
    use std::signer;
    use aptos_framework::timestamp;
    
    struct StakePosition has key, store {
        amount: u64,
        start_time: u64,
        lock_duration: u64,
        accumulated_rewards: u64,
    }
    
    struct StakingPool has key {
        total_staked: u64,
        reward_rate: u64,
        min_stake: u64,
        max_stake: u64,
    }
    
    const E_BELOW_MINIMUM: u64 = 1;
    const E_ABOVE_MAXIMUM: u64 = 2;
    const E_NOT_UNLOCKED: u64 = 3;
    const E_ZERO_AMOUNT: u64 = 4;
    const E_OVERFLOW: u64 = 5;
    const E_NO_POSITION: u64 = 6;
    const E_ALREADY_STAKED: u64 = 7;
    
    const MAX_U64: u64 = 18446744073709551615;
    
    const SECONDS_PER_DAY: u64 = 86400;
    const BASIS_POINTS: u64 = 10000;
    
    public fun calculate_reward(
        stake: &StakePosition,
        pool: &StakingPool,
        current_time: u64
    ): u64 {
        let elapsed = current_time - stake.start_time;
        let days_staked = elapsed / SECONDS_PER_DAY;
        
        if (days_staked == 0) {
            return 0
        };
        
        assert!(stake.amount <= MAX_U64 / pool.reward_rate, E_OVERFLOW);
        let step1 = stake.amount * pool.reward_rate;
        assert!(step1 <= MAX_U64 / days_staked, E_OVERFLOW);
        let base_reward = (step1 * days_staked) / BASIS_POINTS;
        
        let lock_bonus = if (stake.lock_duration >= 365 * SECONDS_PER_DAY) {
            base_reward / 4
        } else if (stake.lock_duration >= 180 * SECONDS_PER_DAY) {
            base_reward / 8
        } else if (stake.lock_duration >= 90 * SECONDS_PER_DAY) {
            base_reward / 16
        } else {
            0
        };
        
        assert!(base_reward <= MAX_U64 - lock_bonus, E_OVERFLOW);
        base_reward + lock_bonus
    }
    
    public fun calculate_compound_reward(
        principal: u64,
        rate: u64,
        periods: u64
    ): u64 {
        let result = principal;
        let i = 0;
        while (i < periods) {
            assert!(result <= MAX_U64 / rate, E_OVERFLOW);
            let interest = (result * rate) / BASIS_POINTS;
            assert!(result <= MAX_U64 - interest, E_OVERFLOW);
            result = result + interest;
            i = i + 1;
        };
        result - principal
    }
    
    public entry fun stake(
        account: &signer,
        amount: u64,
        lock_duration: u64
    ) acquires StakingPool {
        let pool = borrow_global_mut<StakingPool>(@gay);
        
        let addr = signer::address_of(account);
        assert!(!exists<StakePosition>(addr), E_ALREADY_STAKED);
        
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(amount >= pool.min_stake, E_BELOW_MINIMUM);
        assert!(amount <= pool.max_stake, E_ABOVE_MAXIMUM);
        
        let current_time = timestamp::now_seconds();
        
        let position = StakePosition {
            amount,
            start_time: current_time,
            lock_duration,
            accumulated_rewards: 0,
        };
        
        pool.total_staked = pool.total_staked + amount;
        move_to(account, position);
    }
    
    public fun is_unlocked(stake: &StakePosition, current_time: u64): bool {
        current_time >= stake.start_time + stake.lock_duration
    }
    
    public entry fun unstake(
        account: &signer
    ) acquires StakePosition, StakingPool {
        let addr = signer::address_of(account);
        assert!(exists<StakePosition>(addr), E_NO_POSITION);
        let position = move_from<StakePosition>(addr);
        let pool = borrow_global_mut<StakingPool>(@gay);
        
        let current_time = timestamp::now_seconds();
        assert!(is_unlocked(&position, current_time), E_NOT_UNLOCKED);
        
        pool.total_staked = pool.total_staked - position.amount;
        
        let StakePosition { amount: _, start_time: _, lock_duration: _, accumulated_rewards: _ } = position;
    }
    
    #[test]
    fun test_reward_calculation() {
        let stake = StakePosition {
            amount: 10000,
            start_time: 0,
            lock_duration: 0,
            accumulated_rewards: 0,
        };
        let pool = StakingPool {
            total_staked: 100000,
            reward_rate: 100,
            min_stake: 100,
            max_stake: 1000000,
        };
        
        let reward = calculate_reward(&stake, &pool, 30 * SECONDS_PER_DAY);
        assert!(reward == 3000, 0);
    }
    
    #[test]
    fun test_lock_bonus() {
        let stake = StakePosition {
            amount: 10000,
            start_time: 0,
            lock_duration: 365 * SECONDS_PER_DAY,
            accumulated_rewards: 0,
        };
        let pool = StakingPool {
            total_staked: 100000,
            reward_rate: 100,
            min_stake: 100,
            max_stake: 1000000,
        };
        
        let reward = calculate_reward(&stake, &pool, 30 * SECONDS_PER_DAY);
        assert!(reward == 3750, 0);
    }
    
    #[test]
    fun test_compound_reward() {
        let reward = calculate_compound_reward(10000, 100, 12);
        assert!(reward > 1200, 0);
    }
}
