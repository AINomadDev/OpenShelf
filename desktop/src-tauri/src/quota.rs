use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Usage {
    pub used: u64,
    pub total: Option<u64>,
    pub updated: u64,
}

#[derive(Serialize, Debug, PartialEq, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum Level { Unlimited, Ok, Warning, Exceeded }

#[derive(Serialize, Debug, PartialEq)]
pub struct Quota {
    pub used: u64,
    pub limit: Option<u64>,
    pub remaining: Option<u64>,
    pub overage: u64,
    pub fraction: Option<f64>,
    pub level: Level,
}

pub fn quota(used: u64, limit: Option<u64>) -> Quota {
    let Some(limit) = limit.filter(|l| *l > 0) else {
        return Quota { used, limit: None, remaining: None, overage: 0, fraction: None, level: Level::Unlimited };
    };
    let ratio = used as f64 / limit as f64;
    let level = if used >= limit { Level::Exceeded } else if ratio >= 0.8 { Level::Warning } else { Level::Ok };
    Quota { used, limit: Some(limit), remaining: Some(limit.saturating_sub(used)), overage: used.saturating_sub(limit), fraction: Some(ratio.min(1.0)), level }
}

pub fn from_size(json: &str, now: u64) -> Option<Usage> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    Some(Usage { used: v["bytes"].as_u64()?, total: None, updated: now })
}

pub fn from_about(json: &str, now: u64) -> Option<Usage> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let total = v["total"].as_u64();
    let used = v["used"].as_u64().or_else(|| Some(total?.saturating_sub(v["free"].as_u64()?)))?;
    Some(Usage { used, total, updated: now })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn free_tier_levels() {
        let lim = Some(10_000_000_000);
        assert_eq!(quota(0, lim).level, Level::Ok);
        assert_eq!(quota(7_999_999_999, lim).level, Level::Ok);
        assert_eq!(quota(8_000_000_000, lim).level, Level::Warning);
        assert_eq!(quota(10_000_000_000, lim).level, Level::Exceeded);
        let over = quota(12_500_000_000, lim);
        assert_eq!((over.overage, over.remaining, over.fraction), (2_500_000_000, Some(0), Some(1.0)));
        assert_eq!(quota(5, None).level, Level::Unlimited);
    }
    #[test]
    fn parses_rclone_json() {
        assert_eq!(from_size(r#"{"count":5,"bytes":98568,"sizeless":0}"#, 1).unwrap().used, 98568);
        assert_eq!(from_about(r#"{"total":100,"used":40,"free":60}"#, 1).unwrap().total, Some(100));
        assert_eq!(from_about(r#"{"total":100,"free":60}"#, 1).unwrap().used, 40);
        assert!(from_size("garbage", 1).is_none());
    }
}
