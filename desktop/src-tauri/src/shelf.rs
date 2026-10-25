//! Combined view across every space: totals, per-type accounts and pooled free-tier cost.
//! Mirrors `ShelfTotals` and `FreeTierPool` in the macOS app.
use crate::providers;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};

pub struct Item<'a> {
    pub provider: &'a str,
    pub used: u64,
    /// Spaces sharing a provider account (Cloudflare account ID) share one free allowance.
    pub pool: Option<String>,
}

#[derive(Serialize, Debug, Default, PartialEq)]
pub struct TypeRow { pub id: String, pub title: String, pub spaces: u32, pub used: u64 }

#[derive(Serialize, Debug, Default, PartialEq)]
pub struct Shelf {
    pub stored: u64,
    pub free_tier_used: u64,
    pub free_tier_capacity: u64,
    pub free_tier_left: u64,
    pub monthly_cost: f64,
    pub types: Vec<TypeRow>,
}

/// Account ID from an R2 endpoint such as `https://<id>.r2.cloudflarestorage.com`.
pub fn r2_account(endpoint: &str) -> Option<String> {
    let host = endpoint.trim().trim_start_matches("https://").split('/').next()?;
    let (id, rest) = host.split_once('.')?;
    (rest.ends_with("r2.cloudflarestorage.com") && !id.is_empty()).then(|| id.to_string())
}

pub fn summarize(items: &[Item]) -> Shelf {
    let mut shelf = Shelf::default();
    let mut types: BTreeMap<String, TypeRow> = BTreeMap::new();
    let mut groups: HashMap<String, (u64, &providers::Provider)> = HashMap::new();
    for (index, item) in items.iter().enumerate() {
        shelf.stored += item.used;
        let Some(provider) = providers::find(item.provider) else { continue };
        let row = types.entry(provider.id.to_string()).or_insert_with(|| TypeRow { id: provider.id.into(), title: provider.title.into(), ..Default::default() });
        row.spaces += 1;
        row.used += item.used;
        if provider.price_per_gb.is_none() && provider.free_tier.is_none() { continue }
        let key = format!("{}|{}", provider.id, item.pool.clone().unwrap_or_else(|| index.to_string()));
        groups.entry(key).or_insert((0, provider)).0 += item.used;
    }
    for (used, provider) in groups.values() {
        if let Some(free) = provider.free_tier {
            shelf.free_tier_used += (*used).min(free);
            shelf.free_tier_capacity += free;
        }
        if let Some(price) = provider.price_per_gb {
            shelf.monthly_cost += used.saturating_sub(provider.free_tier.unwrap_or(0)) as f64 / 1e9 * price;
        }
    }
    shelf.free_tier_left = shelf.free_tier_capacity.saturating_sub(shelf.free_tier_used);
    shelf.types = types.into_values().collect();
    shelf
}

#[cfg(test)]
mod tests {
    use super::*;
    const GB: u64 = 1_000_000_000;
    fn item(provider: &str, used: u64, pool: Option<&str>) -> Item<'static> {
        Item { provider: Box::leak(provider.to_string().into_boxed_str()), used, pool: pool.map(String::from) }
    }

    #[test]
    fn pools_one_free_tier_per_cloudflare_account() {
        let shelf = summarize(&[item("r2", 7 * GB, Some("acct")), item("r2", 8 * GB, Some("acct")), item("s3", 10 * GB, None)]);
        assert_eq!(shelf.stored, 25 * GB);
        assert_eq!(shelf.free_tier_capacity, 10 * GB);
        assert_eq!(shelf.free_tier_left, 0);
        // R2: 15 GB pooled, 5 GB over at $0.015; S3: 10 GB at $0.023.
        assert!((shelf.monthly_cost - (5.0 * 0.015 + 10.0 * 0.023)).abs() < 1e-9);
        assert_eq!(shelf.types.len(), 2);
    }

    #[test]
    fn spaces_without_a_pool_keep_separate_free_tiers() {
        let shelf = summarize(&[item("b2", 4 * GB, None), item("b2", 3 * GB, None)]);
        assert_eq!(shelf.free_tier_capacity, 20 * GB);
        assert_eq!(shelf.free_tier_left, 13 * GB);
        assert_eq!(shelf.monthly_cost, 0.0);
        assert_eq!(shelf.types[0].spaces, 2);
    }

    #[test]
    fn parses_account_from_endpoint() {
        assert_eq!(r2_account("https://abc123.r2.cloudflarestorage.com").as_deref(), Some("abc123"));
        assert_eq!(r2_account("https://s3.example.com"), None);
    }
}
