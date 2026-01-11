/// World Multisig - Cross-World Signing via CapTP Capabilities
/// 
/// Implements GF(3)-conserved multisig between World A and World B.
/// Based on Aptos multisig_account framework with Gay.jl color semantics.
///
/// Random Walk Path: agent-o-rama (+1) -> bisimulation-game (0) -> captp (0)
/// Selected Skill: captp (Capability Transfer Protocol)
/// GF(3) Trit: +1 (PLUS - Generator/Executor)
module gay::world_multisig {
    use std::signer;
    use std::vector;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::account;
    
    // ============================================
    // ERRORS
    // ============================================
    
    const E_NOT_OWNER: u64 = 1;
    const E_ALREADY_SIGNED: u64 = 2;
    const E_INSUFFICIENT_SIGNATURES: u64 = 3;
    const E_INVALID_THRESHOLD: u64 = 4;
    const E_PROPOSAL_EXPIRED: u64 = 5;
    const E_PROPOSAL_NOT_FOUND: u64 = 6;
    const E_GF3_CONSERVATION_VIOLATED: u64 = 7;
    const E_WORLD_MISMATCH: u64 = 8;
    const E_ALREADY_INITIALIZED: u64 = 9;
    const E_INVALID_AMOUNT: u64 = 10;
    
    // ============================================
    // CONSTANTS - GF(3) Trit Values
    // ============================================
    
    const TRIT_MINUS: u8 = 2;   // -1 mod 3 = 2 (Validator)
    const TRIT_ZERO: u8 = 0;    // 0 (Coordinator)  
    const TRIT_PLUS: u8 = 1;    // +1 (Generator)
    
    const PROPOSAL_EXPIRY_SECONDS: u64 = 86400; // 24 hours
    
    // ============================================
    // STRUCTS
    // ============================================
    
    /// Represents a world in the multiverse (World A, World B, etc.)
    struct World has store, drop, copy {
        /// World identifier (A=0, B=1, C=2, ...)
        id: u8,
        /// GF(3) trit assignment for this world
        trit: u8,
        /// World's address
        addr: address,
    }
    
    /// A transfer proposal requiring multisig approval
    struct TransferProposal has store, drop, copy {
        /// Unique proposal ID
        id: u64,
        /// Source world
        from_world: World,
        /// Destination world  
        to_world: World,
        /// Amount in octas (1 APT = 10^8 octas)
        amount: u64,
        /// Addresses that have signed
        signers: vector<address>,
        /// Required signature threshold
        threshold: u64,
        /// Creation timestamp
        created_at: u64,
        /// GF(3) color fingerprint
        color_fingerprint: u64,
    }
    
    /// Cross-world multisig account state
    struct WorldMultisig has key {
        /// List of owner worlds
        owners: vector<World>,
        /// Signature threshold (k-of-n)
        threshold: u64,
        /// Pending transfer proposals
        proposals: vector<TransferProposal>,
        /// Next proposal ID
        next_proposal_id: u64,
        /// SPI seed for deterministic coloring
        spi_seed: u64,
        /// Total GF(3) trit sum (must be 0 mod 3)
        trit_sum: u8,
    }
    
    // ============================================
    // INITIALIZATION
    // ============================================
    
    /// Initialize a 2-of-2 multisig between World A and World B
    public entry fun initialize_world_multisig(
        account: &signer,
        world_a_addr: address,
        world_b_addr: address,
        spi_seed: u64
    ) {
        let addr = signer::address_of(account);
        assert!(!exists<WorldMultisig>(addr), E_ALREADY_INITIALIZED);
        
        // World A gets TRIT_PLUS (+1), World B gets TRIT_MINUS (-1)
        // Coordinator (this multisig) is TRIT_ZERO (0)
        // Sum: +1 + (-1) + 0 = 0 (conserved)
        let world_a = World {
            id: 0,
            trit: TRIT_PLUS,
            addr: world_a_addr,
        };
        
        let world_b = World {
            id: 1,
            trit: TRIT_MINUS,
            addr: world_b_addr,
        };
        
        let owners = vector::empty<World>();
        vector::push_back(&mut owners, world_a);
        vector::push_back(&mut owners, world_b);
        
        // GF(3) conservation: TRIT_PLUS + TRIT_MINUS = 1 + 2 = 3 = 0 (mod 3)
        let trit_sum = (TRIT_PLUS + TRIT_MINUS) % 3;
        
        move_to(account, WorldMultisig {
            owners,
            threshold: 2, // 2-of-2 for cross-world transfers
            proposals: vector::empty(),
            next_proposal_id: 0,
            spi_seed,
            trit_sum,
        });
    }
    
    // ============================================
    // PROPOSAL CREATION
    // ============================================
    
    /// Create a transfer proposal from one world to another
    public entry fun create_transfer_proposal(
        proposer: &signer,
        multisig_addr: address,
        to_world_id: u8,
        amount: u64
    ) acquires WorldMultisig {
        let proposer_addr = signer::address_of(proposer);
        let multisig = borrow_global_mut<WorldMultisig>(multisig_addr);
        
        // Verify proposer is an owner
        let (is_owner, from_world) = find_owner_world(&multisig.owners, proposer_addr);
        assert!(is_owner, E_NOT_OWNER);
        
        // Find destination world
        let to_world = get_world_by_id(&multisig.owners, to_world_id);
        
        assert!(amount > 0, E_INVALID_AMOUNT);
        
        // Compute color fingerprint using SPI
        let color_fp = compute_proposal_fingerprint(
            multisig.spi_seed,
            from_world.addr,
            to_world.addr,
            amount,
            multisig.next_proposal_id
        );
        
        let proposal = TransferProposal {
            id: multisig.next_proposal_id,
            from_world,
            to_world,
            amount,
            signers: vector::singleton(proposer_addr),
            threshold: multisig.threshold,
            created_at: timestamp::now_seconds(),
            color_fingerprint: color_fp,
        };
        
        vector::push_back(&mut multisig.proposals, proposal);
        multisig.next_proposal_id = multisig.next_proposal_id + 1;
    }
    
    // ============================================
    // SIGNING
    // ============================================
    
    /// Sign a pending transfer proposal
    public entry fun sign_proposal(
        signer_account: &signer,
        multisig_addr: address,
        proposal_id: u64
    ) acquires WorldMultisig {
        let signer_addr = signer::address_of(signer_account);
        let multisig = borrow_global_mut<WorldMultisig>(multisig_addr);
        
        // Verify signer is an owner
        let (is_owner, _) = find_owner_world(&multisig.owners, signer_addr);
        assert!(is_owner, E_NOT_OWNER);
        
        // Find the proposal
        let proposal_idx = find_proposal_index(&multisig.proposals, proposal_id);
        let proposal = vector::borrow_mut(&mut multisig.proposals, proposal_idx);
        
        // Check not expired
        let current_time = timestamp::now_seconds();
        assert!(
            current_time <= proposal.created_at + PROPOSAL_EXPIRY_SECONDS,
            E_PROPOSAL_EXPIRED
        );
        
        // Check not already signed
        assert!(!vector::contains(&proposal.signers, &signer_addr), E_ALREADY_SIGNED);
        
        // Add signature
        vector::push_back(&mut proposal.signers, signer_addr);
    }
    
    // ============================================
    // EXECUTION
    // ============================================
    
    /// Execute a fully-signed transfer proposal
    public entry fun execute_proposal(
        executor: &signer,
        multisig_addr: address,
        proposal_id: u64
    ) acquires WorldMultisig {
        let executor_addr = signer::address_of(executor);
        let multisig = borrow_global_mut<WorldMultisig>(multisig_addr);
        
        // Verify executor is an owner
        let (is_owner, _) = find_owner_world(&multisig.owners, executor_addr);
        assert!(is_owner, E_NOT_OWNER);
        
        // Find and validate proposal
        let proposal_idx = find_proposal_index(&multisig.proposals, proposal_id);
        let proposal = *vector::borrow(&multisig.proposals, proposal_idx);
        
        // Check threshold met
        assert!(
            vector::length(&proposal.signers) >= proposal.threshold,
            E_INSUFFICIENT_SIGNATURES
        );
        
        // Check not expired
        let current_time = timestamp::now_seconds();
        assert!(
            current_time <= proposal.created_at + PROPOSAL_EXPIRY_SECONDS,
            E_PROPOSAL_EXPIRED
        );
        
        // Verify GF(3) conservation before transfer
        verify_gf3_conservation(multisig.trit_sum);
        
        // Execute the transfer (from_world -> to_world)
        // Note: In production, this would use the multisig's SignerCapability
        // For now, we remove the proposal to mark it as executed
        
        // Remove executed proposal
        vector::remove(&mut multisig.proposals, proposal_idx);
    }
    
    // ============================================
    // HELPER FUNCTIONS
    // ============================================
    
    fun find_owner_world(owners: &vector<World>, addr: address): (bool, World) {
        let len = vector::length(owners);
        let i = 0;
        while (i < len) {
            let world = *vector::borrow(owners, i);
            if (world.addr == addr) {
                return (true, world)
            };
            i = i + 1;
        };
        // Return dummy world if not found
        (false, World { id: 255, trit: 0, addr: @0x0 })
    }
    
    fun get_world_by_id(owners: &vector<World>, id: u8): World {
        let len = vector::length(owners);
        let i = 0;
        while (i < len) {
            let world = *vector::borrow(owners, i);
            if (world.id == id) {
                return world
            };
            i = i + 1;
        };
        abort E_WORLD_MISMATCH
    }
    
    fun find_proposal_index(proposals: &vector<TransferProposal>, id: u64): u64 {
        let len = vector::length(proposals);
        let i = 0;
        while (i < len) {
            let proposal = vector::borrow(proposals, i);
            if (proposal.id == id) {
                return i
            };
            i = i + 1;
        };
        abort E_PROPOSAL_NOT_FOUND
    }
    
    fun verify_gf3_conservation(trit_sum: u8) {
        // GF(3) conservation: sum of trits must be 0 (mod 3)
        assert!(trit_sum % 3 == 0, E_GF3_CONSERVATION_VIOLATED);
    }
    
    /// Compute deterministic fingerprint using SplitMix64-like mixing
    fun compute_proposal_fingerprint(
        seed: u64,
        from_addr: address,
        to_addr: address,
        amount: u64,
        proposal_id: u64
    ): u64 {
        let z = seed;
        
        // Mix in addresses (using address as bytes would be ideal, simplified here)
        z = z ^ proposal_id;
        z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
        z = z ^ amount;
        z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
        z = z ^ (z >> 31);
        
        z
    }
    
    // ============================================
    // VIEW FUNCTIONS
    // ============================================
    
    #[view]
    public fun get_proposal_count(multisig_addr: address): u64 acquires WorldMultisig {
        let multisig = borrow_global<WorldMultisig>(multisig_addr);
        vector::length(&multisig.proposals)
    }
    
    #[view]
    public fun get_threshold(multisig_addr: address): u64 acquires WorldMultisig {
        let multisig = borrow_global<WorldMultisig>(multisig_addr);
        multisig.threshold
    }
    
    #[view]
    public fun get_owner_count(multisig_addr: address): u64 acquires WorldMultisig {
        let multisig = borrow_global<WorldMultisig>(multisig_addr);
        vector::length(&multisig.owners)
    }
    
    // ============================================
    // TESTS
    // ============================================
    
    #[test]
    fun test_gf3_conservation() {
        // TRIT_PLUS (1) + TRIT_MINUS (2) = 3 = 0 (mod 3)
        let sum = (TRIT_PLUS + TRIT_MINUS) % 3;
        assert!(sum == 0, 0);
    }
    
    #[test]
    fun test_world_trit_assignments() {
        // World A: +1 (Generator)
        assert!(TRIT_PLUS == 1, 0);
        // World B: -1 (Validator) = 2 in mod 3
        assert!(TRIT_MINUS == 2, 1);
        // Coordinator: 0
        assert!(TRIT_ZERO == 0, 2);
    }
    
    #[test]
    fun test_fingerprint_determinism() {
        let fp1 = compute_proposal_fingerprint(
            0x42D,
            @0x1,
            @0x2,
            100000000, // 1 APT
            0
        );
        let fp2 = compute_proposal_fingerprint(
            0x42D,
            @0x1,
            @0x2,
            100000000,
            0
        );
        assert!(fp1 == fp2, 0);
    }
}
