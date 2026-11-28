//! Memory for host textures only read by shaders: slots in shared heaps.
//! A texture of its own in a committed resource is a driver allocation of
//! 64 KiB at least, made and freed through the kernel; Grand Theft Auto VI
//! streams in tens of thousands, many of some bytes.

use std::collections::BTreeMap;
use std::sync::Mutex;
use windows::Win32::Graphics::Direct3D12::*;

/// Textures larger than this have memory of their own.
const LARGEST: u64 = 8 << 20;

struct Slab {
    /// `None` once no slot was used.
    memory: Option<Memory>,
    free: Vec<u32>,
    slots: u32,
}

#[derive(Clone)]
enum Memory {
    Heap(ID3D12Heap),
    /// An upload buffer and where the CPU writes it.
    Upload(ID3D12Resource, usize),
}

// SAFETY: D3D12 heaps and resources are free-threaded; the CPU pointer is
// only metadata for the owning slab and is never dereferenced on drop.
unsafe impl Send for Memory {}

/// Slot size, and whether for staging, to slabs of such slots.
type Slabs = BTreeMap<(u64, bool), Vec<Slab>>;
static SLABS: Mutex<Slabs> = Mutex::new(BTreeMap::new());

/// A texture's memory, free again when dropped.
pub(crate) struct Slot {
    size: (u64, bool),
    heap: usize,
    index: u32,
}

impl Drop for Slot {
    fn drop(&mut self) {
        let retired = {
            let mut slabs = SLABS.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(s) = slabs.get_mut(&self.size).and_then(|v| v.get_mut(self.heap)) {
                s.free.push(self.index);
                if s.free.len() == s.slots as usize {
                    s.memory.take()
                } else {
                    None
                }
            } else {
                None
            }
        };
        if let Some(mem) = retired {
            crate::host::retire(mem);
        }
    }
}

/// The slot size for `bytes`: a multiple of 4 KiB, or of a sixteenth of its
/// power of two (at least 64 KiB, the placement alignment of larger
/// textures). A mipped block-compressed texture is about four thirds of a
/// power of two, which a step of an eighth rounded up to the next step by
/// up to a sixth of itself.
fn class(bytes: u64) -> u64 {
    if bytes <= 64 << 10 {
        return bytes.next_multiple_of(4 << 10);
    }
    let step = ((bytes.next_power_of_two() / 2) / 8).max(64 << 10);
    bytes.next_multiple_of(step)
}

/// The memory of a slab of slots of `size` bytes, and how many slots it
/// holds. It is cut to whole slots (and to the heap alignment): a heap
/// of 16 MiB for slots of 7 MiB left 2 MiB of it, committed and never used.
fn slab(size: u64) -> (u64, u32) {
    let bytes = (size * 8).clamp(1 << 20, 16 << 20).next_multiple_of(64 << 10);
    let slots = (bytes / size).max(1);
    ((slots * size).next_multiple_of(64 << 10), slots as u32)
}

/// A free slot and its slab's memory, which `make` makes more of.
fn slot(size: (u64, bool), make: impl FnOnce(u64) -> Option<Memory>) -> Option<(Slot, Memory)> {
    let mut slabs = SLABS.lock().unwrap_or_else(|e| e.into_inner());
    let of = slabs.entry(size).or_default();
    let (bytes, slots) = slab(size.0);
    let used = of.iter().position(|s| s.memory.is_some() && !s.free.is_empty());
    let at = match used.or_else(|| of.iter().position(|s| s.memory.is_none())) {
        Some(at) => at,
        None => {
            of.push(Slab {
                memory: None,
                free: (0..slots).rev().collect(),
                slots,
            });
            of.len() - 1
        }
    };
    let s = &mut of[at];
    if s.memory.is_none() {
        s.memory = Some(make(bytes)?);
    }
    let index = s.free.pop()?;
    debug_assert!(index < s.slots);
    Some((Slot { size, heap: at, index }, s.memory.clone()?))
}

/// Upload memory for `bytes`: a buffer, where the CPU writes it from its
/// start, the offset in it; `None` if it is to have a buffer of its own.
pub(crate) fn staging(
    host: &crate::host::Host,
    bytes: u64,
) -> Option<(ID3D12Resource, *mut u8, u64, Slot)> {
    if cfg!(test) || bytes > LARGEST {
        return None;
    }
    let size = class(bytes.max(1));
    let (slot, memory) = slot((size, true), |bytes| {
        let (buffer, data) = host.upload_buffer(bytes)?;
        Some(Memory::Upload(buffer, data as usize))
    })?;
    let Memory::Upload(buffer, data) = memory else {
        return None;
    };
    let offset = u64::from(slot.index) * size;
    Some((buffer, data as *mut u8, offset, slot))
}

/// A texture as `desc` says in `state`, in a slot; `None` if it is to have
/// memory of its own.
pub(crate) fn place(
    device: &ID3D12Device,
    desc: &D3D12_RESOURCE_DESC,
    state: D3D12_RESOURCE_STATES,
) -> Option<(ID3D12Resource, Slot)> {
    if cfg!(test) || desc.Flags.0 != 0 || desc.SampleDesc.Count > 1 {
        return None;
    }
    let mut desc = *desc;
    // Small textures may lie on multiples of 4 KiB.
    desc.Alignment = 4 << 10;
    // SAFETY: a whole description.
    let mut info = unsafe { device.GetResourceAllocationInfo(0, &[desc]) };
    if info.Alignment != 4 << 10 || info.SizeInBytes == u64::MAX {
        desc.Alignment = 0;
        // SAFETY: as above.
        info = unsafe { device.GetResourceAllocationInfo(0, &[desc]) };
    }
    if info.SizeInBytes == 0 || info.SizeInBytes > LARGEST || info.Alignment > 64 << 10 {
        return None;
    }
    let size = class(info.SizeInBytes);
    let (slot, memory) = slot((size, false), |bytes| {
        let heap = D3D12_HEAP_DESC {
            SizeInBytes: bytes,
            Properties: D3D12_HEAP_PROPERTIES {
                Type: D3D12_HEAP_TYPE_DEFAULT,
                ..Default::default()
            },
            Alignment: 64 << 10,
            Flags: D3D12_HEAP_FLAG_ALLOW_ONLY_NON_RT_DS_TEXTURES,
        };
        let mut made: Option<ID3D12Heap> = None;
        // SAFETY: a whole description.
        unsafe { device.CreateHeap(&heap, &mut made) }.ok()?;
        let heap = made?;
        crate::memstat::track(&heap, 4, bytes);
        Some(Memory::Heap(heap))
    })?;
    let Memory::Heap(heap) = memory else {
        return None;
    };
    let mut texture: Option<ID3D12Resource> = None;
    // SAFETY: the slot is inside the heap and no other texture's.
    unsafe {
        device.CreatePlacedResource(
            &heap,
            u64::from(slot.index) * size,
            &desc,
            state,
            None,
            &mut texture,
        )
    }
    .ok()?;
    Some((texture?, slot))
}

/// Diagnostics: for textures and for staging, the bytes of the slabs that
/// have memory, the bytes of their slots in use, how many slabs, and the
/// size class that wastes most with its slab and used bytes.
#[cfg(feature = "diagnostics")]
pub(crate) fn census() -> [(u64, u64, u64, (u64, u64, u64)); 2] {
    let slabs = SLABS.lock().unwrap_or_else(|e| e.into_inner());
    let mut out = [(0, 0, 0, (0, 0, 0)); 2];
    for (&(size, staging), of) in slabs.iter() {
        let (mut held, mut used, mut count) = (0u64, 0u64, 0u64);
        for s in of.iter().filter(|s| s.memory.is_some()) {
            held += u64::from(s.slots) * size;
            used += (u64::from(s.slots) - s.free.len() as u64) * size;
            count += 1;
        }
        let o = &mut out[usize::from(staging)];
        (o.0, o.1, o.2) = (o.0 + held, o.1 + used, o.2 + count);
        if held - used > o.3.1 - o.3.2 {
            o.3 = (size, held, used);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const KIB: u64 = 1 << 10;
    const MIB: u64 = 1 << 20;

    /// The sizes a driver reports: multiples of 4 KiB up to 64 KiB, of
    /// 64 KiB above, up to the largest texture of a slot.
    fn sizes() -> impl Iterator<Item = u64> {
        (1..=16).map(|k| k * 4 * KIB).chain((2..=LARGEST / (64 * KIB)).map(|k| k * 64 * KIB))
    }

    #[test]
    fn a_class_holds_its_bytes_on_the_placement_alignment() {
        for bytes in (1..=LARGEST).step_by(509) {
            let c = class(bytes);
            assert!(c >= bytes, "{bytes} in {c}");
            assert_eq!(c % (4 * KIB), 0, "{bytes}");
            if bytes > 64 * KIB {
                assert_eq!(c % (64 * KIB), 0, "{bytes}");
                assert!(c <= bytes.next_power_of_two(), "{bytes} in {c}");
            }
        }
    }

    #[test]
    fn a_class_is_its_own_class_and_never_shrinks() {
        let mut last = 0;
        for bytes in sizes() {
            let c = class(bytes);
            assert_eq!(class(c), c, "{bytes}");
            assert!(c >= last, "{bytes}");
            last = c;
        }
    }

    #[test]
    fn a_class_wastes_under_an_eighth_above_half_a_mebibyte() {
        for bytes in sizes().filter(|&b| b > MIB / 2) {
            let waste = class(bytes) - bytes;
            assert!(waste * 8 < bytes, "{bytes} wastes {waste}");
        }
    }

    #[test]
    fn a_mipped_block_compressed_texture_fits_exactly() {
        // 1024 x 1024 of 16-byte blocks, with its mips, on 64 KiB: 1.375 MiB.
        let bytes = 11 * 128 * KIB;
        assert_eq!(class(bytes), bytes);
        // 2048 x 2048 of 8-byte blocks, with its mips: 2.75 MiB.
        let bytes = 22 * 128 * KIB;
        assert_eq!(class(bytes), bytes);
    }

    #[test]
    fn a_slab_is_whole_slots_in_a_heap_of_the_alignment() {
        for size in sizes().map(class) {
            let (bytes, slots) = slab(size);
            assert!(slots >= 1, "{size}");
            assert_eq!(bytes % (64 * KIB), 0, "{size}");
            assert!(u64::from(slots) * size <= bytes, "{size}");
            // Nothing is left but what the alignment adds.
            assert!(bytes - u64::from(slots) * size < 64 * KIB, "{size}");
            assert!(bytes <= 16 * MIB, "{size}");
        }
    }

    #[test]
    fn a_slab_of_big_slots_does_not_keep_a_tail() {
        // Of 16 MiB, two slots of 7 MiB use 14 MiB; the heap is 14 MiB.
        assert_eq!(slab(7 * MIB), (14 * MIB, 2));
        assert_eq!(slab(3 * MIB), (15 * MIB, 5));
        // Small slots still fill a megabyte or more.
        assert_eq!(slab(4 * KIB), (MIB, 256));
    }
}
