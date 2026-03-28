module gay::multiverse {
    use std::signer;
    use aptos_framework::coin;
    
    struct Partition has key, store {
        energy: u64,
        mass: u64,
        dimension: u8,
    }
    
    struct MultiverseState has key {
        total_partitions: u64,
        total_energy: u64,
    }
    
    const E_INSUFFICIENT_ENERGY: u64 = 1;
    const E_INVALID_PARTITION: u64 = 2;
    const E_CONSERVATION_VIOLATED: u64 = 3;
    const E_OVERFLOW: u64 = 4;
    const E_ALREADY_EXISTS: u64 = 5;
    
    const MAX_U64: u64 = 18446744073709551615;
    
    public entry fun create_partition(
        account: &signer,
        energy: u64,
        mass: u64,
        dimension: u8
    ) acquires MultiverseState {
        let addr = signer::address_of(account);
        assert!(!exists<Partition>(addr), E_ALREADY_EXISTS);
        
        let state = borrow_global_mut<MultiverseState>(@gay);
        
        assert!(energy > 0, E_INSUFFICIENT_ENERGY);
        
        let partition = Partition {
            energy,
            mass,
            dimension,
        };
        
        state.total_partitions = state.total_partitions + 1;
        state.total_energy = state.total_energy + energy;
        
        move_to(account, partition);
    }
    
    public fun partition_energy(partition: &Partition): u64 {
        partition.energy + partition.mass * 2
    }
    
    public fun merge_partitions(
        p1: Partition,
        p2: Partition
    ): Partition {
        assert!(p1.energy <= MAX_U64 - p2.energy, E_OVERFLOW);
        assert!(p1.mass <= MAX_U64 - p2.mass, E_OVERFLOW);
        
        let total_energy = p1.energy + p2.energy;
        let total_mass = p1.mass + p2.mass;
        let max_dim = if (p1.dimension > p2.dimension) { p1.dimension } else { p2.dimension };
        
        assert!(total_energy >= p1.energy && total_energy >= p2.energy, E_CONSERVATION_VIOLATED);
        
        let Partition { energy: _, mass: _, dimension: _ } = p1;
        let Partition { energy: _, mass: _, dimension: _ } = p2;
        
        Partition {
            energy: total_energy,
            mass: total_mass,
            dimension: max_dim,
        }
    }
    
    public fun split_partition(
        partition: Partition,
        ratio_numerator: u64,
        ratio_denominator: u64
    ): (Partition, Partition) {
        assert!(ratio_denominator > 0, E_INVALID_PARTITION);
        assert!(ratio_numerator <= ratio_denominator, E_INVALID_PARTITION);
        
        let Partition { energy, mass, dimension } = partition;
        
        assert!(energy <= MAX_U64 / ratio_numerator || ratio_numerator == 0, E_OVERFLOW);
        let energy1 = (energy * ratio_numerator) / ratio_denominator;
        let energy2 = energy - energy1;
        let mass1 = (mass * ratio_numerator) / ratio_denominator;
        let mass2 = mass - mass1;
        
        assert!(energy1 + energy2 == energy, E_CONSERVATION_VIOLATED);
        
        (
            Partition { energy: energy1, mass: mass1, dimension },
            Partition { energy: energy2, mass: mass2, dimension }
        )
    }
    
    #[test]
    fun test_partition_conservation() {
        let p1 = Partition { energy: 100, mass: 50, dimension: 3 };
        let p2 = Partition { energy: 200, mass: 75, dimension: 5 };
        
        let merged = merge_partitions(p1, p2);
        assert!(merged.energy == 300, 0);
        assert!(merged.mass == 125, 1);
    }
    
    #[test]
    fun test_split_conservation() {
        let p = Partition { energy: 100, mass: 50, dimension: 3 };
        let (p1, p2) = split_partition(p, 1, 4);
        
        assert!(p1.energy + p2.energy == 100, 0);
    }
    
    #[test]
    fun test_partition_energy_calculation() {
        let p = Partition { energy: 100, mass: 25, dimension: 3 };
        assert!(partition_energy(&p) == 150, 0);
    }
}
