module gay::spi_verifier {
    use std::signer;
    use std::vector;
    
    // Prover configuration: specify bv (bitvector) encoding for bitwise ops
    spec module {
        pragma verify = true;
    }
    
    const E_FINGERPRINT_MISMATCH: u64 = 100;
    const E_CONSERVATION_VIOLATION: u64 = 101;
    const E_INVALID_CHECKPOINT: u64 = 102;
    const E_REPLAY_DETECTED: u64 = 103;
    const E_INVALID_TRANSITION: u64 = 104;
    
    struct SPICheckpoint has store, drop, copy {
        fingerprint: u64,
        total_energy: u64,
        total_mass: u64,
        partition_count: u64,
        nonce: u64,
    }
    
    struct VerifierState has key {
        seed: u64,
        checkpoints: vector<SPICheckpoint>,
        last_fingerprint: u64,
        transition_count: u64,
    }
    
    struct MarketState has store, drop, copy {
        energy: u64,
        mass: u64,
        dimension: u8,
    }
    
    // ============================================
    // SPLITMIX64 PRNG - Deterministic fingerprints
    // ============================================
    
    fun splitmix64(seed: &mut u64): u64 {
        *seed = *seed + 0x9e3779b97f4a7c15;
        let z = *seed;
        z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
        z ^ (z >> 31)
    }
    spec splitmix64 {
        pragma opaque;
        pragma bv = b"0";
        pragma bv_ret = b"0";
    }
    
    fun mix_u64(seed: &mut u64, value: u64): u64 {
        *seed = *seed ^ value;
        splitmix64(seed)
    }
    spec mix_u64 {
        pragma opaque;
        pragma bv = b"01";
        pragma bv_ret = b"0";
    }
    
    fun mix_u8(seed: &mut u64, value: u8): u64 {
        mix_u64(seed, (value as u64))
    }
    spec mix_u8 {
        pragma opaque;
        pragma bv = b"01";
        pragma bv_ret = b"0";
    }
    
    // ============================================
    // FINGERPRINT COMPUTATION
    // ============================================
    
    public fun compute_state_fingerprint(
        energy: u64,
        mass: u64,
        dimension: u8,
        nonce: u64
    ): u64 {
        let seed = 0x123456789abcdef0u64;
        mix_u64(&mut seed, energy);
        mix_u64(&mut seed, mass);
        mix_u8(&mut seed, dimension);
        mix_u64(&mut seed, nonce)
    }
    spec compute_state_fingerprint {
        pragma opaque;
        pragma bv = b"0111";
        pragma bv_ret = b"0";
    }
    
    public fun compute_partition_fingerprint(
        energies: &vector<u64>,
        masses: &vector<u64>,
        nonce: u64
    ): u64 {
        let seed = 0xfedcba9876543210u64;
        let len = vector::length(energies);
        let i = 0;
        while (i < len) {
            mix_u64(&mut seed, *vector::borrow(energies, i));
            mix_u64(&mut seed, *vector::borrow(masses, i));
            i = i + 1;
        };
        mix_u64(&mut seed, nonce)
    }
    spec compute_partition_fingerprint {
        pragma opaque;
        pragma bv = b"001";
        pragma bv_ret = b"0";
    }
    
    // ============================================
    // MARKET INTEGRITY VERIFICATION
    // ============================================
    
    public fun verify_market_integrity(
        pre_state: &MarketState,
        post_state: &MarketState,
        expected_delta_energy: u64,
        expected_delta_mass: u64,
        is_addition: bool
    ): bool {
        let expected_energy = if (is_addition) {
            pre_state.energy + expected_delta_energy
        } else {
            pre_state.energy - expected_delta_energy
        };
        
        let expected_mass = if (is_addition) {
            pre_state.mass + expected_delta_mass
        } else {
            pre_state.mass - expected_delta_mass
        };
        
        post_state.energy == expected_energy && post_state.mass == expected_mass
    }
    
    public fun verify_conservation(
        pre_energies: &vector<u64>,
        pre_masses: &vector<u64>,
        post_energies: &vector<u64>,
        post_masses: &vector<u64>
    ): bool {
        let pre_total_energy = sum_vector(pre_energies);
        let pre_total_mass = sum_vector(pre_masses);
        let post_total_energy = sum_vector(post_energies);
        let post_total_mass = sum_vector(post_masses);
        
        pre_total_energy == post_total_energy && pre_total_mass == post_total_mass
    }
    
    fun sum_vector(v: &vector<u64>): u64 {
        let sum = 0u64;
        let len = vector::length(v);
        let i = 0;
        while (i < len) {
            sum = sum + *vector::borrow(v, i);
            i = i + 1;
        };
        sum
    }
    
    // ============================================
    // CHECKPOINT MANAGEMENT
    // ============================================
    
    public entry fun initialize(account: &signer, initial_seed: u64) {
        let addr = signer::address_of(account);
        move_to(account, VerifierState {
            seed: initial_seed,
            checkpoints: vector::empty(),
            last_fingerprint: 0,
            transition_count: 0,
        });
    }
    
    public fun create_checkpoint(
        verifier: &mut VerifierState,
        total_energy: u64,
        total_mass: u64,
        partition_count: u64
    ): SPICheckpoint {
        let nonce = splitmix64(&mut verifier.seed);
        let fingerprint = compute_state_fingerprint(
            total_energy,
            total_mass,
            (partition_count as u8),
            nonce
        );
        
        let checkpoint = SPICheckpoint {
            fingerprint,
            total_energy,
            total_mass,
            partition_count,
            nonce,
        };
        
        vector::push_back(&mut verifier.checkpoints, checkpoint);
        verifier.last_fingerprint = fingerprint;
        verifier.transition_count = verifier.transition_count + 1;
        
        checkpoint
    }
    
    public fun verify_checkpoint(
        checkpoint: &SPICheckpoint,
        expected_energy: u64,
        expected_mass: u64,
        expected_count: u64
    ): bool {
        let recomputed = compute_state_fingerprint(
            expected_energy,
            expected_mass,
            (expected_count as u8),
            checkpoint.nonce
        );
        
        checkpoint.fingerprint == recomputed &&
        checkpoint.total_energy == expected_energy &&
        checkpoint.total_mass == expected_mass &&
        checkpoint.partition_count == expected_count
    }
    
    // ============================================
    // PARTITION/MERGE/RESOLVE HOOKS
    // ============================================
    
    public fun verify_partition_split(
        verifier: &mut VerifierState,
        pre_energy: u64,
        pre_mass: u64,
        post_energy_1: u64,
        post_mass_1: u64,
        post_energy_2: u64,
        post_mass_2: u64
    ) {
        assert!(
            pre_energy == post_energy_1 + post_energy_2,
            E_CONSERVATION_VIOLATION
        );
        assert!(
            pre_mass == post_mass_1 + post_mass_2,
            E_CONSERVATION_VIOLATION
        );
        
        let pre_fp = compute_state_fingerprint(pre_energy, pre_mass, 1, verifier.seed);
        let post_fp_1 = compute_state_fingerprint(post_energy_1, post_mass_1, 1, verifier.seed);
        let post_fp_2 = compute_state_fingerprint(post_energy_2, post_mass_2, 1, verifier.seed);
        
        let combined_post = post_fp_1 ^ post_fp_2;
        verifier.last_fingerprint = combined_post;
        verifier.transition_count = verifier.transition_count + 1;
    }
    
    public fun verify_partition_merge(
        verifier: &mut VerifierState,
        pre_energy_1: u64,
        pre_mass_1: u64,
        pre_energy_2: u64,
        pre_mass_2: u64,
        post_energy: u64,
        post_mass: u64
    ) {
        assert!(
            pre_energy_1 + pre_energy_2 == post_energy,
            E_CONSERVATION_VIOLATION
        );
        assert!(
            pre_mass_1 + pre_mass_2 == post_mass,
            E_CONSERVATION_VIOLATION
        );
        
        let post_fp = compute_state_fingerprint(post_energy, post_mass, 1, verifier.seed);
        verifier.last_fingerprint = post_fp;
        verifier.transition_count = verifier.transition_count + 1;
    }
    
    public fun verify_market_resolve(
        verifier: &mut VerifierState,
        winning_energy: u64,
        losing_energy: u64,
        resolution_fingerprint: u64
    ) {
        let expected_fp = compute_state_fingerprint(
            winning_energy + losing_energy,
            0,
            2,
            verifier.seed
        );
        
        assert!(
            (expected_fp ^ verifier.last_fingerprint) == resolution_fingerprint,
            E_FINGERPRINT_MISMATCH
        );
        
        verifier.last_fingerprint = resolution_fingerprint;
        verifier.transition_count = verifier.transition_count + 1;
    }
    
    // ============================================
    // MULTIVERSE INTEGRATION HOOKS
    // ============================================
    
    public fun hook_pre_partition(
        verifier: &mut VerifierState,
        energy: u64,
        mass: u64,
        dimension: u8
    ): u64 {
        let nonce = splitmix64(&mut verifier.seed);
        compute_state_fingerprint(energy, mass, dimension, nonce)
    }
    
    public fun hook_post_partition(
        verifier: &mut VerifierState,
        pre_fingerprint: u64,
        post_energy: u64,
        post_mass: u64,
        post_dimension: u8
    ) {
        let nonce = splitmix64(&mut verifier.seed);
        let post_fp = compute_state_fingerprint(post_energy, post_mass, post_dimension, nonce);
        
        let transition_hash = pre_fingerprint ^ post_fp ^ verifier.last_fingerprint;
        verifier.last_fingerprint = transition_hash;
        verifier.transition_count = verifier.transition_count + 1;
    }
    
    public fun get_verifier_state(verifier: &VerifierState): (u64, u64, u64) {
        (verifier.last_fingerprint, verifier.transition_count, vector::length(&verifier.checkpoints))
    }
    
    // ============================================
    // TESTS
    // ============================================
    
    #[test]
    fun test_splitmix64_determinism() {
        let seed1 = 12345u64;
        let seed2 = 12345u64;
        
        let r1 = splitmix64(&mut seed1);
        let r2 = splitmix64(&mut seed2);
        
        assert!(r1 == r2, 0);
        assert!(seed1 == seed2, 1);
    }
    
    #[test]
    fun test_fingerprint_consistency() {
        let fp1 = compute_state_fingerprint(100, 50, 3, 999);
        let fp2 = compute_state_fingerprint(100, 50, 3, 999);
        let fp3 = compute_state_fingerprint(100, 50, 3, 1000);
        
        assert!(fp1 == fp2, 0);
        assert!(fp1 != fp3, 1);
    }
    
    #[test]
    fun test_conservation_check() {
        let pre_e = vector::empty<u64>();
        vector::push_back(&mut pre_e, 100);
        vector::push_back(&mut pre_e, 200);
        
        let pre_m = vector::empty<u64>();
        vector::push_back(&mut pre_m, 50);
        vector::push_back(&mut pre_m, 75);
        
        let post_e = vector::empty<u64>();
        vector::push_back(&mut post_e, 150);
        vector::push_back(&mut post_e, 150);
        
        let post_m = vector::empty<u64>();
        vector::push_back(&mut post_m, 60);
        vector::push_back(&mut post_m, 65);
        
        assert!(verify_conservation(&pre_e, &pre_m, &post_e, &post_m), 0);
    }
    
    #[test]
    fun test_market_integrity() {
        let pre = MarketState { energy: 100, mass: 50, dimension: 3 };
        let post = MarketState { energy: 150, mass: 75, dimension: 3 };
        
        assert!(verify_market_integrity(&pre, &post, 50, 25, true), 0);
    }
    
    #[test]
    fun test_checkpoint_verification() {
        let checkpoint = SPICheckpoint {
            fingerprint: compute_state_fingerprint(100, 50, 3, 12345),
            total_energy: 100,
            total_mass: 50,
            partition_count: 3,
            nonce: 12345,
        };
        
        assert!(verify_checkpoint(&checkpoint, 100, 50, 3), 0);
        assert!(!verify_checkpoint(&checkpoint, 101, 50, 3), 1);
    }
}
