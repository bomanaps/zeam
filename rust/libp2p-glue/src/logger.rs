use std::fmt::Write;

pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevel {}

fn level_code(level: &LogLevel) -> u32 {
    match level {
        LogLevel::Debug => 0,
        LogLevel::Info => 1,
        LogLevel::Warn => 2,
        LogLevel::Error => 3,
    }
}

// Build a plain message string (optionally with a [module] prefix) and forward to Zig

fn log_with_level(level: LogLevel, network_id: u32, module: Option<&str>, message: &str) {
    let mut output = String::new();
    if let Some(module) = module {
        let _ = write!(output, "[{}] ", module);
    }
    let _ = write!(output, "{}", message);

    crate::forward_log_by_network(network_id, level_code(&level), &output);
}

pub fn log_debug(network_id: u32, message: &str) {
    log_with_level(LogLevel::Debug, network_id, None, message);
}

pub fn log_info(network_id: u32, message: &str) {
    log_with_level(LogLevel::Info, network_id, None, message);
}

pub fn log_warn(network_id: u32, message: &str) {
    log_with_level(LogLevel::Warn, network_id, None, message);
}

pub fn log_error(network_id: u32, message: &str) {
    log_with_level(LogLevel::Error, network_id, None, message);
}

pub fn log_debug_module(network_id: u32, module: &str, message: &str) {
    log_with_level(LogLevel::Debug, network_id, Some(module), message);
}

pub fn log_info_module(network_id: u32, module: &str, message: &str) {
    log_with_level(LogLevel::Info, network_id, Some(module), message);
}

pub fn log_warn_module(network_id: u32, module: &str, message: &str) {
    log_with_level(LogLevel::Warn, network_id, Some(module), message);
}

pub fn log_error_module(network_id: u32, module: &str, message: &str) {
    log_with_level(LogLevel::Error, network_id, Some(module), message);
}
