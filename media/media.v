module media

pub struct Part {
pub:
	index       int
	total_parts int
	bytes       []u8
}

pub struct TransferProgress {
pub:
	transferred u64
	total       u64
}
