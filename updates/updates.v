module updates

pub struct StateVector {
pub:
	pts  i64
	qts  i64
	seq  int
	date int
}

pub struct SubscriptionConfig {
pub:
	buffer_size int = 64
	drop_oldest bool
}
