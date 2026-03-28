/// Formal verification specifications for Gay.jl Move contracts
/// Run with: aptos move prove

// ============================================
// MULTIVERSE SPECIFICATIONS
// ============================================

spec gay::multiverse {
    spec Partition {
        invariant energy >= 0;
        invariant dimension <= 255;
    }
    
    spec MultiverseState {
        invariant total_partitions >= 0;
        invariant total_energy >= 0;
    }
    
    spec merge_partitions {
        aborts_if p1.energy + p2.energy > MAX_U64;
        ensures result.energy == p1.energy + p2.energy;
        ensures result.mass == p1.mass + p2.mass;
        ensures result.dimension >= p1.dimension || result.dimension >= p2.dimension;
    }
    
    spec split_partition {
        aborts_if ratio_denominator == 0;
        aborts_if ratio_numerator > ratio_denominator;
    }
    
    spec create_partition {
        aborts_if energy == 0;
        aborts_if !exists<MultiverseState>(@gay);
    }
    
    spec partition_energy {
        aborts_if partition.mass * 2 > MAX_U64 - partition.energy;
        ensures result == partition.energy + partition.mass * 2;
    }
}

// ============================================
// STAKING SPECIFICATIONS  
// ============================================

spec gay::staking {
    spec StakePosition {
        invariant amount >= 0;
        invariant accumulated_rewards >= 0;
    }
    
    spec StakingPool {
        invariant min_stake <= max_stake;
        invariant total_staked >= 0;
        invariant reward_rate <= 10000;
    }
    
    spec unstake {
        let addr = signer::address_of(account);
        aborts_if !exists<StakePosition>(addr);
        aborts_if !exists<StakingPool>(@gay);
    }
    
    spec stake {
        aborts_if amount == 0;
        aborts_if !exists<StakingPool>(@gay);
        let pool = global<StakingPool>(@gay);
        aborts_if amount < pool.min_stake;
        aborts_if amount > pool.max_stake;
    }
    
    spec calculate_reward {
        aborts_if current_time < stake.start_time;
    }
    
    spec calculate_compound_reward {
        aborts_if principal == 0;
        ensures result >= 0;
    }
    
    spec is_unlocked {
        aborts_if stake.start_time + stake.lock_duration > MAX_U64;
        ensures result == (current_time >= stake.start_time + stake.lock_duration);
    }
}

// ============================================
// GITHUB BOUNTY SPECIFICATIONS
// ============================================

spec gay::github_bounty {
    spec Bounty {
        invariant importance >= 1 && importance <= 4;
        invariant reward_amount >= 0;
    }
    
    spec BountyRegistry {
        invariant total_rewards >= 0;
        invariant importance_multiplier_base > 0;
    }
    
    spec claim_bounty {
        aborts_if !exists<BountyRegistry>(@gay);
    }
    
    spec create_bounty {
        aborts_if importance < 1 || importance > 4;
        aborts_if !exists<BountyRegistry>(@gay);
    }
    
    spec calculate_importance_multiplier {
        aborts_if importance < 1 || importance > 4;
        ensures result >= base_multiplier;
        ensures result <= base_multiplier * 4;
    }
    
    spec calculate_priority_score {
        ensures result <= 30 + 100 + 50;
        ensures result >= 0;
    }
    
    spec calculate_effective_reward {
        aborts_if importance < 1 || importance > 4;
    }
}
