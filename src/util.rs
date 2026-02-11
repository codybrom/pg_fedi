use serde_json::Value;

/// Extract a string field from a JSON object.
pub fn json_str(obj: &Value, key: &str) -> Option<String> {
    obj.get(key).and_then(|v| v.as_str()).map(|s| s.to_string())
}

/// Extract a string from a nested JSON path.
pub fn json_str_nested(obj: &Value, keys: &[&str]) -> Option<String> {
    let mut current = obj;
    for key in keys {
        current = current.get(*key)?;
    }
    current.as_str().map(|s| s.to_string())
}

/// Simple domain extraction from a URI without pulling in the `url` crate.
pub fn parse_domain(uri: &str) -> Option<String> {
    let after_scheme = uri
        .strip_prefix("https://")
        .or_else(|| uri.strip_prefix("http://"))?;
    let host = after_scheme.split('/').next()?;
    let domain = host.split(':').next()?;
    Some(domain.to_string())
}
