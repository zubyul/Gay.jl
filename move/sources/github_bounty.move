module gay::github_bounty {
    use std::signer;
    use std::string::String;
    use std::vector;
    
    struct Bounty has key, store {
        repo_owner: String,
        repo_name: String,
        issue_number: u64,
        reward_amount: u64,
        importance: u8,
        is_claimed: bool,
    }
    
    struct BountyRegistry has key {
        bounties: vector<Bounty>,
        total_rewards: u64,
        importance_multiplier_base: u64,
    }
    
    const E_BOUNTY_NOT_FOUND: u64 = 1;
    const E_ALREADY_CLAIMED: u64 = 2;
    const E_INVALID_IMPORTANCE: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    const E_OVERFLOW: u64 = 5;
    const E_DIVISION_BY_ZERO: u64 = 6;
    
    const MAX_U64: u64 = 18446744073709551615;
    
    const IMPORTANCE_LOW: u8 = 1;
    const IMPORTANCE_MEDIUM: u8 = 2;
    const IMPORTANCE_HIGH: u8 = 3;
    const IMPORTANCE_CRITICAL: u8 = 4;
    
    public fun calculate_importance_multiplier(
        importance: u8,
        base_multiplier: u64
    ): u64 {
        assert!(importance >= IMPORTANCE_LOW && importance <= IMPORTANCE_CRITICAL, E_INVALID_IMPORTANCE);
        assert!(base_multiplier <= MAX_U64 / 4, E_OVERFLOW);
        
        if (importance == IMPORTANCE_CRITICAL) {
            base_multiplier * 4
        } else if (importance == IMPORTANCE_HIGH) {
            base_multiplier * 2
        } else if (importance == IMPORTANCE_MEDIUM) {
            (base_multiplier * 3) / 2
        } else {
            base_multiplier
        }
    }
    
    public fun calculate_effective_reward(
        base_reward: u64,
        importance: u8,
        contributor_score: u64,
        base_multiplier: u64
    ): u64 {
        assert!(base_multiplier > 0, E_DIVISION_BY_ZERO);
        let importance_mult = calculate_importance_multiplier(importance, base_multiplier);
        
        let score_bonus = if (contributor_score >= 1000) {
            base_reward / 4
        } else if (contributor_score >= 500) {
            base_reward / 8
        } else if (contributor_score >= 100) {
            base_reward / 16
        } else {
            0
        };
        
        assert!(base_reward <= MAX_U64 / importance_mult, E_OVERFLOW);
        let base_with_importance = (base_reward * importance_mult) / base_multiplier;
        assert!(base_with_importance <= MAX_U64 - score_bonus, E_OVERFLOW);
        base_with_importance + score_bonus
    }
    
    public fun calculate_priority_score(
        age_days: u64,
        importance: u8,
        num_applicants: u64
    ): u64 {
        assert!(importance >= IMPORTANCE_LOW && importance <= IMPORTANCE_CRITICAL, E_INVALID_IMPORTANCE);
        
        let age_factor = if (age_days > 30) { 30 } else { age_days };
        let importance_factor = (importance as u64) * 25;
        let competition_factor = if (num_applicants > 10) { 0 } else { 10 - num_applicants };
        
        age_factor + importance_factor + competition_factor * 5
    }
    
    public entry fun create_bounty(
        account: &signer,
        repo_owner: String,
        repo_name: String,
        issue_number: u64,
        reward_amount: u64,
        importance: u8
    ) acquires BountyRegistry {
        assert!(importance >= IMPORTANCE_LOW && importance <= IMPORTANCE_CRITICAL, E_INVALID_IMPORTANCE);
        
        let registry = borrow_global_mut<BountyRegistry>(@gay);
        
        let bounty = Bounty {
            repo_owner,
            repo_name,
            issue_number,
            reward_amount,
            importance,
            is_claimed: false,
        };
        
        vector::push_back(&mut registry.bounties, bounty);
        assert!(registry.total_rewards <= MAX_U64 - reward_amount, E_OVERFLOW);
        registry.total_rewards = registry.total_rewards + reward_amount;
    }
    
    public fun find_bounty_index(
        bounties: &vector<Bounty>,
        issue_number: u64
    ): (bool, u64) {
        let len = vector::length(bounties);
        let i = 0;
        while (i < len) {
            let bounty = vector::borrow(bounties, i);
            if (bounty.issue_number == issue_number) {
                return (true, i)
            };
            i = i + 1;
        };
        (false, 0)
    }
    
    public entry fun claim_bounty(
        account: &signer,
        issue_number: u64
    ) acquires BountyRegistry {
        let registry = borrow_global_mut<BountyRegistry>(@gay);
        
        let (found, index) = find_bounty_index(&registry.bounties, issue_number);
        assert!(found, E_BOUNTY_NOT_FOUND);
        
        let bounty = vector::borrow_mut(&mut registry.bounties, index);
        assert!(!bounty.is_claimed, E_ALREADY_CLAIMED);
        
        bounty.is_claimed = true;
    }
    
    #[test]
    fun test_importance_multiplier() {
        let mult = calculate_importance_multiplier(IMPORTANCE_CRITICAL, 100);
        assert!(mult == 400, 0);
        
        let mult_high = calculate_importance_multiplier(IMPORTANCE_HIGH, 100);
        assert!(mult_high == 200, 1);
    }
    
    #[test]
    fun test_effective_reward() {
        let reward = calculate_effective_reward(1000, IMPORTANCE_HIGH, 500, 100);
        assert!(reward == 2125, 0);
    }
    
    #[test]
    fun test_priority_score() {
        let score = calculate_priority_score(15, IMPORTANCE_HIGH, 5);
        assert!(score == 90, 0);
    }
}
