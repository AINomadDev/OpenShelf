use serde::Serialize;
use std::collections::HashMap;

#[derive(Serialize, Clone, Copy)]
pub struct Field {
    pub key: &'static str,
    pub label: &'static str,
    pub secret: bool,
    pub placeholder: &'static str,
}

#[derive(Serialize, Clone, Copy)]
pub struct Provider {
    pub id: &'static str,
    pub title: &'static str,
    pub backend: &'static str,
    pub s3_flavor: Option<&'static str>,
    pub free_tier: Option<u64>,
    pub charges_egress: bool,
    pub price_per_gb: Option<f64>,
    pub egress_note: &'static str,
    pub console_url: &'static str,
    pub steps: &'static [&'static str],
    pub fields: &'static [Field],
}

const fn f(key: &'static str, label: &'static str, secret: bool, placeholder: &'static str) -> Field {
    Field { key, label, secret, placeholder }
}

const S3_KEYS: [Field; 2] = [f("access_key_id", "Access key ID", false, ""), f("secret_access_key", "Secret access key", true, "")];

pub const PROVIDERS: &[Provider] = &[
    Provider { id: "r2", title: "Cloudflare R2", backend: "s3", s3_flavor: Some("Cloudflare"), free_tier: Some(10_000_000_000), charges_egress: false, price_per_gb: Some(0.015),
        egress_note: "R2 charges no egress fees. Storage beyond 10 GB and requests beyond the free tier are billed.",
        console_url: "https://dash.cloudflare.com/?to=/:account/r2/overview",
        steps: &["Create a bucket in R2.", "Copy your Account ID from the R2 overview page.", "Create an API token with Object Read & Write limited to that bucket.", "Paste the Account ID (or full endpoint URL) and the key pair below."],
        fields: &[f("account_id", "Account ID or endpoint URL", false, "32-character ID"), S3_KEYS[0], S3_KEYS[1]] },
    Provider { id: "b2", title: "Backblaze B2", backend: "b2", s3_flavor: None, free_tier: Some(10_000_000_000), charges_egress: false, price_per_gb: Some(0.0069),
        egress_note: "B2 downloads are free up to 3x your average stored data, then billed per GB.",
        console_url: "https://secure.backblaze.com/b2_buckets.htm",
        steps: &["Create a private bucket.", "Add an application key restricted to that bucket.", "Copy the keyID and applicationKey now; the key is shown once."],
        fields: &[f("account", "Application key ID", false, ""), f("key", "Application key", true, "")] },
    Provider { id: "e2", title: "IDrive e2", backend: "s3", s3_flavor: Some("IDrive"), free_tier: Some(10_000_000_000), charges_egress: false, price_per_gb: Some(0.005),
        egress_note: "e2 includes a free download allowance based on your stored data; check your plan.",
        console_url: "https://app.idrivee2.com/",
        steps: &["Create a bucket.", "Create an access key.", "Copy the endpoint shown for your bucket's region."],
        fields: &[f("endpoint", "Endpoint", false, "https://...idrivee2-....com"), S3_KEYS[0], S3_KEYS[1]] },
    Provider { id: "s3", title: "Amazon S3", backend: "s3", s3_flavor: Some("AWS"), free_tier: None, charges_egress: true, price_per_gb: Some(0.023),
        egress_note: "Downloads are billed per GB. Archive here; restore only when needed.",
        console_url: "https://console.aws.amazon.com/s3/",
        steps: &["Create a private bucket.", "Create an IAM user limited to that bucket.", "Create an access key and copy both values."],
        fields: &[f("region", "Region", false, "us-east-1"), S3_KEYS[0], S3_KEYS[1]] },
    Provider { id: "gcs", title: "Google Cloud Storage", backend: "google cloud storage", s3_flavor: None, free_tier: None, charges_egress: true, price_per_gb: Some(0.02),
        egress_note: "Downloads are billed per GB. Archive here; restore only when needed.",
        console_url: "https://console.cloud.google.com/storage/browser",
        steps: &["Create a bucket.", "Create a service account with Storage Object User on that bucket only.", "Download a JSON key and enter its file path. Never commit it."],
        fields: &[f("credential_file", "Service-account JSON file path", false, "/path/to/key.json")] },
    Provider { id: "azure", title: "Azure Blob Storage", backend: "azureblob", s3_flavor: None, free_tier: None, charges_egress: true, price_per_gb: Some(0.0208),
        egress_note: "Downloads are billed per GB. Archive here; restore only when needed.",
        console_url: "https://portal.azure.com/#browse/Microsoft.Storage%2FStorageAccounts",
        steps: &["Create a container.", "Generate a SAS with the permissions you need and an expiry.", "Paste the full SAS URL."],
        fields: &[f("sas_url", "SAS URL", true, "https://...")] },
    Provider { id: "wasabi", title: "Wasabi", backend: "s3", s3_flavor: Some("Wasabi"), free_tier: None, charges_egress: false, price_per_gb: Some(0.0069),
        egress_note: "Wasabi has no egress or request fees under its fair-use policy. Storage is billed with a 1 TB minimum and 90-day minimum retention.",
        console_url: "https://console.wasabisys.com/",
        steps: &["Create a bucket and note its region.", "Create an access key.", "The endpoint is s3.<region>.wasabisys.com."],
        fields: &[f("endpoint", "Endpoint", false, "https://s3.eu-central-1.wasabisys.com"), S3_KEYS[0], S3_KEYS[1]] },
    Provider { id: "hetzner", title: "Hetzner Object Storage", backend: "s3", s3_flavor: Some("Hetzner"), free_tier: None, charges_egress: false, price_per_gb: Some(0.0065),
        egress_note: "Hetzner includes 1 TB of outbound traffic with the base price, then bills extra per TB.",
        console_url: "https://console.hetzner.cloud/",
        steps: &["Create a bucket under Object Storage and note its location.", "Create S3 credentials for the project.", "The endpoint is <location>.your-objectstorage.com."],
        fields: &[f("endpoint", "Endpoint", false, "https://fsn1.your-objectstorage.com"), S3_KEYS[0], S3_KEYS[1]] },
    Provider { id: "storj", title: "Storj", backend: "s3", s3_flavor: Some("Storj"), free_tier: None, charges_egress: true, price_per_gb: Some(0.004),
        egress_note: "Storj bills egress per GB (about $0.007/GB), so archive here and restore only when needed.",
        console_url: "https://storj.io/",
        steps: &["Create a bucket in the Storj console.", "Generate S3 credentials with the permissions you need.", "The endpoint is https://gateway.storjshare.io."],
        fields: &[f("endpoint", "Endpoint", false, "https://gateway.storjshare.io"), S3_KEYS[0], S3_KEYS[1]] },
    Provider { id: "do", title: "DigitalOcean Spaces", backend: "s3", s3_flavor: Some("DigitalOcean"), free_tier: None, charges_egress: false, price_per_gb: Some(0.02),
        egress_note: "Spaces bundles 1 TB of outbound transfer with the base plan, then bills extra per GB.",
        console_url: "https://cloud.digitalocean.com/spaces",
        steps: &["Create a Space and note its region.", "Generate a Spaces key pair under API.", "The endpoint is <region>.digitaloceanspaces.com."],
        fields: &[f("endpoint", "Endpoint", false, "https://nyc3.digitaloceanspaces.com"), S3_KEYS[0], S3_KEYS[1]] },
    Provider { id: "s3c", title: "S3-compatible storage", backend: "s3", s3_flavor: Some("Other"), free_tier: None, charges_egress: true, price_per_gb: None,
        egress_note: "Check your provider's download and request pricing.",
        console_url: "",
        steps: &["Create a bucket and access key in your provider's console.", "Copy the S3 endpoint and region."],
        fields: &[f("endpoint", "Endpoint", false, "https://..."), f("region", "Region", false, "us-east-1"), S3_KEYS[0], S3_KEYS[1]] },
];

pub fn find(id: &str) -> Option<&'static Provider> { PROVIDERS.iter().find(|p| p.id == id) }

pub fn r2_account_id(input: &str) -> Option<String> {
    let text = input.trim().trim_start_matches("https://");
    let host = text.split('/').next().unwrap_or("");
    let id = host.strip_suffix(".r2.cloudflarestorage.com").unwrap_or(host);
    (!id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric())).then(|| id.to_string())
}

pub fn https(input: &str) -> String {
    let text = input.trim();
    if text.contains("://") { text.to_string() } else { format!("https://{text}") }
}

fn valid_https(url: &str) -> bool {
    url.strip_prefix("https://").map_or(false, |rest| {
        let host = rest.split('/').next().unwrap_or("");
        !host.is_empty() && !host.contains('@')
    })
}

/// Produces the rclone key/values for a new space. Never logs or returns secrets elsewhere.
pub fn build_config(provider: &Provider, fields: &HashMap<String, String>) -> Result<Vec<(String, String)>, String> {
    let get = |key: &str| fields.get(key).map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
    let need = |key: &str, label: &str| get(key).ok_or_else(|| format!("Please provide {label}."));
    if fields.values().any(|v| v.contains('\n') || v.contains('\r')) {
        return Err("Credential fields cannot contain line breaks.".into());
    }
    let mut out = vec![("type".to_string(), provider.backend.to_string())];
    match provider.id {
        "b2" => {
            out.push(("account".into(), need("account", "the application key ID")?));
            out.push(("key".into(), need("key", "the application key")?));
        }
        "gcs" => {
            let path = need("credential_file", "the service-account JSON file")?;
            let data = std::fs::read_to_string(&path).map_err(|_| "Could not read the credential file.".to_string())?;
            let value: serde_json::Value = serde_json::from_str(&data).map_err(|_| "Choose a Google service-account JSON file.".to_string())?;
            if value["type"] != "service_account" { return Err("Choose a Google service-account JSON file.".into()); }
            out.push(("bucket_policy_only".into(), "true".into()));
            out.push(("service_account_credentials".into(), value.to_string()));
        }
        "azure" => {
            let sas = need("sas_url", "the SAS URL")?;
            if !valid_https(&sas) || !sas.contains('?') { return Err("Enter a valid HTTPS endpoint or SAS URL.".into()); }
            out.push(("sas_url".into(), sas));
        }
        _ => {
            out.push(("provider".into(), provider.s3_flavor.unwrap_or("Other").into()));
            out.push(("no_check_bucket".into(), "true".into()));
            out.push(("access_key_id".into(), need("access_key_id", "the access key ID")?));
            out.push(("secret_access_key".into(), need("secret_access_key", "the secret access key")?));
            match provider.id {
                "r2" => {
                    let id = r2_account_id(&need("account_id", "the Cloudflare account ID")?).ok_or("Enter a valid HTTPS endpoint or SAS URL.")?;
                    out.push(("endpoint".into(), format!("https://{id}.r2.cloudflarestorage.com")));
                    out.push(("region".into(), "auto".into()));
                }
                "e2" | "wasabi" | "do" | "hetzner" | "storj" | "s3c" => {
                    let endpoint = https(&need("endpoint", "the endpoint")?);
                    if !valid_https(&endpoint) { return Err("Enter a valid HTTPS endpoint or SAS URL.".into()); }
                    out.push(("endpoint".into(), endpoint));
                    if provider.id == "s3c" { out.push(("region".into(), get("region").unwrap_or("us-east-1".into()))); }
                }
                _ => out.push(("region".into(), get("region").unwrap_or("us-east-1".into()))),
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> { pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect() }
    fn lookup(cfg: &[(String, String)], key: &str) -> Option<String> { cfg.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone()) }

    #[test]
    fn r2_builds_endpoint_from_id_or_url() {
        let p = find("r2").unwrap();
        for input in ["abc123", "https://abc123.r2.cloudflarestorage.com/bucket"] {
            let cfg = build_config(p, &map(&[("account_id", input), ("access_key_id", "k"), ("secret_access_key", "s")])).unwrap();
            assert_eq!(lookup(&cfg, "endpoint").unwrap(), "https://abc123.r2.cloudflarestorage.com");
            assert_eq!(lookup(&cfg, "provider").unwrap(), "Cloudflare");
        }
        assert!(build_config(p, &map(&[("account_id", "bad id!"), ("access_key_id", "k"), ("secret_access_key", "s")])).is_err());
    }
    #[test]
    fn b2_uses_native_backend() {
        let cfg = build_config(find("b2").unwrap(), &map(&[("account", " id "), ("key", "k")])).unwrap();
        assert_eq!(lookup(&cfg, "type").unwrap(), "b2");
        assert_eq!(lookup(&cfg, "account").unwrap(), "id");
    }
    #[test]
    fn e2_adds_scheme_and_rejects_http_credentials() {
        let p = find("e2").unwrap();
        let cfg = build_config(p, &map(&[("endpoint", "s3.example.com"), ("access_key_id", "k"), ("secret_access_key", "s")])).unwrap();
        assert_eq!(lookup(&cfg, "endpoint").unwrap(), "https://s3.example.com");
        assert!(build_config(p, &map(&[("endpoint", "https://u:p@x.com"), ("access_key_id", "k"), ("secret_access_key", "s")])).is_err());
    }
    #[test]
    fn newlines_and_missing_fields_rejected() {
        let p = find("b2").unwrap();
        assert!(build_config(p, &map(&[("account", "a\nb"), ("key", "k")])).is_err());
        assert!(build_config(p, &map(&[("account", "a")])).is_err());
    }
    #[test]
    fn every_provider_has_guide_and_fields() {
        for p in PROVIDERS { assert!(!p.steps.is_empty() && !p.fields.is_empty() && !p.egress_note.is_empty()); }
        assert!(PROVIDERS.iter().filter(|p| p.free_tier == Some(10_000_000_000)).count() == 3);
    }
}

/// Estimated monthly storage cost in dollars at list price, after any free allowance.
pub fn monthly_cost(provider: &Provider, used: u64) -> Option<f64> {
    let price = provider.price_per_gb?;
    Some(used.saturating_sub(provider.free_tier.unwrap_or(0)) as f64 / 1e9 * price)
}

#[cfg(test)]
mod pricing_tests {
    use super::*;
    #[test]
    fn estimates_after_free_tier() {
        let r2 = find("r2").unwrap();
        assert_eq!(monthly_cost(r2, 5_000_000_000), Some(0.0));
        assert!((monthly_cost(r2, 110_000_000_000).unwrap() - 1.5).abs() < 1e-9);
        assert!((monthly_cost(find("gcs").unwrap(), 17_700_000_000).unwrap() - 0.354).abs() < 1e-9);
        assert_eq!(monthly_cost(find("s3c").unwrap(), 1), None);
    }
    #[test]
    fn new_providers_build_s3_config() {
        let mut m = HashMap::new();
        m.insert("endpoint".to_string(), "s3.eu-central-1.wasabisys.com".to_string());
        m.insert("access_key_id".to_string(), "k".to_string());
        m.insert("secret_access_key".to_string(), "s".to_string());
        let cfg = build_config(find("wasabi").unwrap(), &m).unwrap();
        assert!(cfg.contains(&("provider".to_string(), "Wasabi".to_string())));
        assert!(cfg.contains(&("endpoint".to_string(), "https://s3.eu-central-1.wasabisys.com".to_string())));
    }
}

#[cfg(test)]
mod catalogue_tests {
    use super::*;

    #[test]
    fn matches_shared_catalogue() {
        let doc: serde_json::Value = serde_json::from_str(include_str!("../../../providers.json")).unwrap();
        let entries = doc["providers"].as_array().unwrap();
        assert_eq!(entries.len(), PROVIDERS.len());
        for entry in entries {
            let id = entry["id"].as_str().unwrap();
            let p = PROVIDERS.iter().find(|p| p.id == id).unwrap_or_else(|| panic!("missing {id}"));
            assert_eq!(entry["title"], p.title, "{id} title");
            assert_eq!(entry["backend"], p.backend, "{id} backend");
            assert_eq!(entry["s3Flavor"].as_str(), p.s3_flavor, "{id} flavor");
            assert_eq!(entry["freeTierBytes"].as_u64(), p.free_tier, "{id} free tier");
            assert_eq!(entry["chargesEgress"].as_bool().unwrap(), p.charges_egress, "{id} egress");
            assert_eq!(entry["pricePerGb"].as_f64(), p.price_per_gb, "{id} price");
        }
    }
}
