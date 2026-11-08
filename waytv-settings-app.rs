// WayTV Settings App v1.0 (Rust + egui)
// Android TV native settings: Home, Display, Apps, Storage, About tabs
// Builds as APK with cargo-ndk for aarch64-linux-android or x86_64-linux-android

use eframe::egui;
use std::sync::{Arc, Mutex};
use std::thread;

const AGENT_URL: &str = "http://192.168.240.1:8765";
const AGENT_TOKEN: &str = "waytv-secret";

#[derive(Clone, Debug)]
enum Tab {
    Home,
    Display,
    Apps,
    Storage,
    About,
}

#[derive(Clone, Debug)]
struct SystemInfo {
    ip: String,
    hostname: String,
    android_version: String,
    gapps_status: String,
    free_space: f64,
    total_space: f64,
}

impl Default for SystemInfo {
    fn default() -> Self {
        Self {
            ip: "192.168.1.157".to_string(),
            hostname: "waytv-box".to_string(),
            android_version: "17".to_string(),
            gapps_status: "yes".to_string(),
            free_space: 8.8,
            total_space: 14.0,
        }
    }
}

struct WayTVApp {
    current_tab: Tab,
    system_info: Arc<Mutex<SystemInfo>>,
    selected_dpi: u32,
    launchers: Vec<(String, String)>,
    selected_launcher: usize,
    message: String,
    message_timeout: u32,
}

impl Default for WayTVApp {
    fn default() -> Self {
        Self {
            current_tab: Tab::Home,
            system_info: Arc::new(Mutex::new(SystemInfo::default())),
            selected_dpi: 240,
            launchers: vec![
                ("Projectivity".to_string(), "com.projectivity.launcher".to_string()),
                ("AT4K".to_string(), "com.overdevs.at4k".to_string()),
            ],
            selected_launcher: 0,
            message: String::new(),
            message_timeout: 0,
        }
    }
}

impl eframe::App for WayTVApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Decrement message timeout
        if self.message_timeout > 0 {
            self.message_timeout -= 1;
        } else {
            self.message.clear();
        }

        // Top panel: tab navigation
        egui::TopBottomPanel::top("tabs").show(ctx, |ui| {
            ui.horizontal(|ui| {
                if ui.button("Home (↑)").clicked() || ui.input(|i| i.key_pressed(egui::Key::ArrowUp)) {
                    self.current_tab = Tab::Home;
                }
                if ui.button("Display (→)").clicked() {
                    self.current_tab = Tab::Display;
                }
                if ui.button("Apps (→)").clicked() {
                    self.current_tab = Tab::Apps;
                }
                if ui.button("Storage (→)").clicked() {
                    self.current_tab = Tab::Storage;
                }
                if ui.button("About (→)").clicked() {
                    self.current_tab = Tab::About;
                }
            });
        });

        // Central panel: tab content
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("WayTV Settings");

            match self.current_tab {
                Tab::Home => self.show_home_tab(ui),
                Tab::Display => self.show_display_tab(ui),
                Tab::Apps => self.show_apps_tab(ui),
                Tab::Storage => self.show_storage_tab(ui),
                Tab::About => self.show_about_tab(ui),
            }

            // Status message
            if !self.message.is_empty() {
                ui.colored_label(egui::Color32::YELLOW, &self.message);
            }
        });

        // Request repaint for animation/updates
        ctx.request_repaint_after(std::time::Duration::from_millis(100));
    }
}

impl WayTVApp {
    fn show_home_tab(&self, ui: &mut egui::Ui) {
        ui.label("Device Information");
        ui.separator();

        let info = self.system_info.lock().unwrap();
        ui.label(format!("IP Address: {}", info.ip));
        ui.label(format!("Hostname: {}", info.hostname));
        ui.label(format!("Android Version: {}", info.android_version));
        ui.label(format!("GApps Status: {}", info.gapps_status));
        ui.label(format!("Free Storage: {:.1} GB / {:.1} GB", info.free_space, info.total_space));

        if ui.button("Refresh (A)") {
            // Placeholder: would call agent API to refresh
        }
    }

    fn show_display_tab(&mut self, ui: &mut egui::Ui) {
        ui.label("Display Settings");
        ui.separator();

        ui.label("Screen DPI (Density)");
        let mut dpi_str = self.selected_dpi.to_string();
        if ui.text_edit_singleline(&mut dpi_str) {
            if let Ok(dpi) = dpi_str.parse::<u32>() {
                if dpi >= 100 && dpi <= 800 {
                    self.selected_dpi = dpi;
                }
            }
        }

        if ui.button("Apply DPI (A)") || ui.input(|i| i.key_pressed(egui::Key::Enter)) {
            self.message = format!("Setting DPI to {}", self.selected_dpi);
            self.message_timeout = 60;
            // Placeholder: would call agent POST /api/display/dpi
        }

        ui.label("Common presets:");
        if ui.button("1080p (240 dpi)") {
            self.selected_dpi = 240;
            self.message = "Set to 1080p scaling".to_string();
            self.message_timeout = 60;
        }
        if ui.button("4K Small (360 dpi)") {
            self.selected_dpi = 360;
            self.message = "Set to 4K small scaling".to_string();
            self.message_timeout = 60;
        }
        if ui.button("4K Normal (480 dpi)") {
            self.selected_dpi = 480;
            self.message = "Set to 4K normal scaling".to_string();
            self.message_timeout = 60;
        }

        if ui.button("Reset (B)") {
            self.selected_dpi = 240;
            self.message = "Scaling reset to default".to_string();
            self.message_timeout = 60;
        }
    }

    fn show_apps_tab(&mut self, ui: &mut egui::Ui) {
        ui.label("Applications");
        ui.separator();

        ui.label("Select Home Screen Launcher:");
        for (i, (name, _pkg)) in self.launchers.iter().enumerate() {
            if ui.selectable_label(self.selected_launcher == i, name) {
                self.selected_launcher = i;
            }
        }

        if ui.button("Set as Default (A)") {
            let pkg = &self.launchers[self.selected_launcher].1;
            self.message = format!("Set {} as default launcher", pkg);
            self.message_timeout = 60;
            // Placeholder: would call agent POST /api/apps/launcher-set
        }

        ui.separator();
        ui.label("Installed Apps:");
        ui.label("com.example.app1 (tap A to uninstall)");
        ui.label("com.example.app2 (tap A to uninstall)");
        ui.label("com.example.app3 (tap A to uninstall)");

        if ui.button("Back (B)") {
            // Navigation back
        }
    }

    fn show_storage_tab(&self, ui: &mut egui::Ui) {
        ui.label("Storage Information");
        ui.separator();

        let info = self.system_info.lock().unwrap();
        ui.label(format!("Used: {:.1} GB", info.total_space - info.free_space));
        ui.label(format!("Free: {:.1} GB", info.free_space));
        ui.label(format!("Total: {:.1} GB", info.total_space));

        let used_ratio = (info.total_space - info.free_space) / info.total_space;
        ui.add(
            egui::ProgressBar::new(used_ratio as f32)
                .text(format!("{:.0}%", used_ratio * 100.0)),
        );

        if ui.button("Clear Cache (A)") {
            // Placeholder: would call agent to clear cache
        }
    }

    fn show_about_tab(&self, ui: &mut egui::Ui) {
        ui.label("About WayTV");
        ui.separator();

        ui.label("WayTV Settings v1.0");
        ui.label("Android TV native settings application");
        ui.label("Built with Rust + egui");

        if ui.button("Check for Updates (A)") {
            // Placeholder: would check for app updates
        }

        if ui.button("Reset to Defaults (B)") {
            // Placeholder: would reset settings
        }
    }
}

fn main() -> Result<(), eframe::Error> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_fullscreen(false)
            .with_title_bar(true),
        ..Default::default()
    };

    eframe::run_native(
        "WayTV Settings",
        options,
        Box::new(|_cc| Ok(Box::<WayTVApp>::default())),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_system_info_default() {
        let info = SystemInfo::default();
        assert_eq!(info.ip, "192.168.1.157");
        assert_eq!(info.android_version, "17");
    }

    #[test]
    fn test_app_initialization() {
        let app = WayTVApp::default();
        assert_eq!(app.selected_dpi, 240);
        assert_eq!(app.launchers.len(), 2);
    }
}
