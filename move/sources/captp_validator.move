/// CapTP-style Multisig Validator for GayMove
/// MINUS (-1) Trit Agent: Validation/Constrainer Layer
/// 
/// This module implements the validation constraints for CapTP-style
/// capability handoff between World A and World B Aptos wallets.
module gay_move::captp_validator {
    use std::error;
    use std::vector;
    use std::signer;
    use std::hash;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::multisig_account;
    use aptos_framework::timestamp;
    use aptos_framework::event;

    // ============================================================
    // GF(3) TRIT CONSTANTS
    // ============================================================
    
    /// GF(3) trit values for triadic coordination
    /// In GF(3): -1 ≡ 2 (mod 3)
    const TRIT_MINUS: u8 = 2;    // Validator/Constrainer
    const TRIT_ERGODIC: u8 = 0;  // Coordinator/Synthesizer
    const TRIT_PLUS: u8 = 1;     // Generator/Executor

    // ============================================================
    // ERROR CODES
    // ============================================================
    
    const E_INVALID_TRIT_SUM: u64 = 1001;
    const E_INVALID_SESSION_BINDING: u64 = 1002;
    const E_CAPABILITY_REPLAY: u64 = 1003;
    const E_BISIMULATION_FAILURE: u64 = 1004;
    const E_HANDOFF_CHAIN_INVALID: u64 = 1005;
    const E_NOT_MULTISIG_OWNER: u64 = 1006;
    const E_PAYLOAD_HASH_MISMATCH: u64 = 1007;
    const E_SESSION_EXPIRED: u64 = 1008;

    // ============================================================
    // CAPTP HANDOFF STRUCTURES
    // ============================================================

    /// CapTP-style handoff-give certificate
    /// Represents the sealed capability being transferred
    struct HandoffGive has copy, drop, store {
        /// Recipient's public key hash (World B)
        recipient_key_hash: vector<u8>,
        /// Unique session identifier (32 bytes)
        session_id: vector<u8>,
        /// Gifter's address (World A)
        gifter_side: address,
        /// Gift identifier (maps to sequence_number)
        gift_id: u64,
        /// SHA3-256 hash of the transaction payload
        payload_hash: vector<u8>,
        /// Timestamp when handoff was created
        created_at: u64,
    }

    /// CapTP-style handoff-receive certificate
    /// Represents the receiver's acceptance of the capability
    struct HandoffReceive has copy, drop, store {
        /// Session ID (must match give)
        session_id: vector<u8>,
        /// Receiver's address (World B)
        receiver_side: address,
        /// Monotonic counter for replay prevention
        handoff_count: u64,
        /// The original handoff-give being acknowledged
        signed_give_hash: vector<u8>,
        /// Receiver's signature over the give
        signature: vector<u8>,
    }

    /// Bisimulation game state for signing validation
    struct BisimulationState has key, store {
        /// Current game round
        round: u8,
        /// Attacker (proposer) address
        attacker: address,
        /// Defender (approver) address
        defender: address,
        /// Pending handoff-give
        pending_give: Option<HandoffGive>,
        /// Received handoff-receive
        pending_receive: Option<HandoffReceive>,
        /// Game outcome (0 = ongoing, 1 = defender wins, 2 = attacker wins)
        outcome: u8,
    }

    /// Session registry to track active capability transfers
    struct SessionRegistry has key {
        /// Active sessions mapped by session_id
        sessions: SimpleMap<vector<u8>, SessionState>,
        /// Last used handoff count per session (anti-replay)
        handoff_counts: SimpleMap<vector<u8>, u64>,
    }

    struct SessionState has store, drop {
        gifter: address,
        receiver: address,
        multisig_addr: address,
        created_at: u64,
        expires_at: u64,
        trit_assignments: vector<u8>, // [gifter_trit, receiver_trit, multisig_trit]
    }

    // ============================================================
    // EVENTS
    // ============================================================

    #[event]
    struct HandoffInitiated has drop, store {
        session_id: vector<u8>,
        gifter: address,
        receiver: address,
        gift_id: u64,
    }

    #[event]
    struct HandoffCompleted has drop, store {
        session_id: vector<u8>,
        multisig_addr: address,
        sequence_number: u64,
    }

    #[event]
    struct BisimulationVerified has drop, store {
        session_id: vector<u8>,
        attacker: address,
        defender: address,
        outcome: u8,
    }

    #[event]
    struct GF3ConservationChecked has drop, store {
        trits: vector<u8>,
        sum_mod_3: u8,
        valid: bool,
    }

    // ============================================================
    // CORE VALIDATION FUNCTIONS
    // ============================================================

    /// Validate GF(3) conservation across the triad
    /// MINUS agent's primary responsibility
    public fun validate_gf3_conservation(
        proposer_trit: u8,
        validator_trit: u8,
        executor_trit: u8
    ): bool {
        // GF(3) conservation law: sum must be 0 (mod 3)
        let sum = ((proposer_trit as u64) + (validator_trit as u64) + (executor_trit as u64)) % 3;
        
        event::emit(GF3ConservationChecked {
            trits: vector[proposer_trit, validator_trit, executor_trit],
            sum_mod_3: (sum as u8),
            valid: sum == 0,
        });
        
        sum == 0
    }

    /// Validate a complete handoff chain
    public fun validate_handoff_chain(
        give: &HandoffGive,
        receive: &HandoffReceive,
        multisig_addr: address
    ): bool acquires SessionRegistry {
        // 1. Session IDs must match
        if (give.session_id != receive.session_id) {
            return false
        };

        // 2. Payload hash must be valid (32 bytes for SHA3-256)
        if (vector::length(&give.payload_hash) != 32) {
            return false
        };

        // 3. Verify handoff-receive references the handoff-give
        let give_hash = hash::sha3_256(bcs::to_bytes(give));
        if (receive.signed_give_hash != give_hash) {
            return false
        };

        // 4. Check replay prevention (handoff_count must be monotonically increasing)
        if (!check_handoff_count(&give.session_id, receive.handoff_count)) {
            return false
        };

        // 5. Verify both parties are owners of the multisig
        if (!multisig_account::is_owner(give.gifter_side, multisig_addr)) {
            return false
        };
        if (!multisig_account::is_owner(receive.receiver_side, multisig_addr)) {
            return false
        };

        true
    }

    /// Check and update handoff count for replay prevention
    fun check_handoff_count(session_id: &vector<u8>, new_count: u64): bool acquires SessionRegistry {
        let registry = borrow_global_mut<SessionRegistry>(@gay_move);
        
        if (simple_map::contains_key(&registry.handoff_counts, session_id)) {
            let last_count = *simple_map::borrow(&registry.handoff_counts, session_id);
            if (new_count <= last_count) {
                return false
            };
        };
        
        // Update the count
        if (simple_map::contains_key(&registry.handoff_counts, session_id)) {
            *simple_map::borrow_mut(&mut registry.handoff_counts, session_id) = new_count;
        } else {
            simple_map::add(&mut registry.handoff_counts, *session_id, new_count);
        };
        
        true
    }

    // ============================================================
    // BISIMULATION GAME PROTOCOL
    // ============================================================

    /// Initialize a bisimulation game for signing validation
    public fun init_bisimulation_game(
        attacker: address,
        defender: address,
        multisig_addr: address
    ): BisimulationState {
        BisimulationState {
            round: 0,
            attacker,
            defender,
            pending_give: option::none(),
            pending_receive: option::none(),
            outcome: 0, // Ongoing
        }
    }

    /// Round 1: Attacker proposes handoff-give
    public fun bisim_round_propose(
        state: &mut BisimulationState,
        give: HandoffGive
    ) {
        assert!(state.round == 0, error::invalid_state(E_BISIMULATION_FAILURE));
        assert!(give.gifter_side == state.attacker, error::permission_denied(E_NOT_MULTISIG_OWNER));
        
        state.pending_give = option::some(give);
        state.round = 1;
    }

    /// Round 2: Defender responds with handoff-receive
    public fun bisim_round_respond(
        state: &mut BisimulationState,
        receive: HandoffReceive
    ) {
        assert!(state.round == 1, error::invalid_state(E_BISIMULATION_FAILURE));
        assert!(receive.receiver_side == state.defender, error::permission_denied(E_NOT_MULTISIG_OWNER));
        
        state.pending_receive = option::some(receive);
        state.round = 2;
    }

    /// Round 3: Validate bisimulation and determine outcome
    public fun bisim_round_validate(
        state: &mut BisimulationState,
        multisig_addr: address
    ): bool acquires SessionRegistry {
        assert!(state.round == 2, error::invalid_state(E_BISIMULATION_FAILURE));
        
        let give = option::borrow(&state.pending_give);
        let receive = option::borrow(&state.pending_receive);
        
        // Validate the handoff chain
        let chain_valid = validate_handoff_chain(give, receive, multisig_addr);
        
        // Validate GF(3) conservation
        // Attacker = PLUS (+1), Defender = MINUS (-1), Multisig = ERGODIC (0)
        let gf3_valid = validate_gf3_conservation(TRIT_PLUS, TRIT_MINUS, TRIT_ERGODIC);
        
        if (chain_valid && gf3_valid) {
            state.outcome = 1; // Defender wins - transaction can proceed
            
            event::emit(BisimulationVerified {
                session_id: give.session_id,
                attacker: state.attacker,
                defender: state.defender,
                outcome: 1,
            });
            
            true
        } else {
            state.outcome = 2; // Attacker wins - validation failed
            
            event::emit(BisimulationVerified {
                session_id: give.session_id,
                attacker: state.attacker,
                defender: state.defender,
                outcome: 2,
            });
            
            false
        }
    }

    // ============================================================
    // SESSION MANAGEMENT
    // ============================================================

    /// Create a new capability transfer session
    public entry fun create_session(
        gifter: &signer,
        receiver: address,
        multisig_addr: address,
        session_duration_secs: u64
    ) acquires SessionRegistry {
        let gifter_addr = signer::address_of(gifter);
        
        // Verify both are multisig owners
        assert!(
            multisig_account::is_owner(gifter_addr, multisig_addr),
            error::permission_denied(E_NOT_MULTISIG_OWNER)
        );
        assert!(
            multisig_account::is_owner(receiver, multisig_addr),
            error::permission_denied(E_NOT_MULTISIG_OWNER)
        );
        
        // Generate session ID
        let now = timestamp::now_seconds();
        let session_seed = vector::empty<u8>();
        vector::append(&mut session_seed, bcs::to_bytes(&gifter_addr));
        vector::append(&mut session_seed, bcs::to_bytes(&receiver));
        vector::append(&mut session_seed, bcs::to_bytes(&now));
        let session_id = hash::sha3_256(session_seed);
        
        let session = SessionState {
            gifter: gifter_addr,
            receiver,
            multisig_addr,
            created_at: now,
            expires_at: now + session_duration_secs,
            trit_assignments: vector[TRIT_PLUS, TRIT_MINUS, TRIT_ERGODIC],
        };
        
        let registry = borrow_global_mut<SessionRegistry>(@gay_move);
        simple_map::add(&mut registry.sessions, session_id, session);
        
        event::emit(HandoffInitiated {
            session_id,
            gifter: gifter_addr,
            receiver,
            gift_id: 0,
        });
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    #[view]
    /// Check if a session is still valid
    public fun is_session_valid(session_id: vector<u8>): bool acquires SessionRegistry {
        let registry = borrow_global<SessionRegistry>(@gay_move);
        
        if (!simple_map::contains_key(&registry.sessions, &session_id)) {
            return false
        };
        
        let session = simple_map::borrow(&registry.sessions, &session_id);
        let now = timestamp::now_seconds();
        
        now < session.expires_at
    }

    #[view]
    /// Get the trit assignment for a participant in a session
    public fun get_trit_assignment(
        session_id: vector<u8>,
        participant: address
    ): u8 acquires SessionRegistry {
        let registry = borrow_global<SessionRegistry>(@gay_move);
        let session = simple_map::borrow(&registry.sessions, &session_id);
        
        if (participant == session.gifter) {
            TRIT_PLUS
        } else if (participant == session.receiver) {
            TRIT_MINUS
        } else if (participant == session.multisig_addr) {
            TRIT_ERGODIC
        } else {
            255 // Invalid
        }
    }

    #[view]
    /// Verify GF(3) conservation for given trits
    public fun verify_conservation(trits: vector<u8>): bool {
        let sum: u64 = 0;
        let i = 0;
        let len = vector::length(&trits);
        
        while (i < len) {
            sum = sum + (*vector::borrow(&trits, i) as u64);
            i = i + 1;
        };
        
        (sum % 3) == 0
    }

    // ============================================================
    // INITIALIZATION
    // ============================================================

    /// Initialize the module (called once on deployment)
    fun init_module(deployer: &signer) {
        move_to(deployer, SessionRegistry {
            sessions: simple_map::create(),
            handoff_counts: simple_map::create(),
        });
    }
}
