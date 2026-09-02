//! ChatAI UI components.
//!
//! Every component here is a struct with a `pub fn render(self, cx: *Cx)
//! void` method, which is all `cx.render` needs to compose it into a tree.
//! `layout.zig` assembles the root from these; components reach for each
//! other directly rather than through this barrel so the dependency edges
//! stay visible in each file's imports.

pub const constants = @import("constants.zig");

pub const ComposerActions = @import("composer_actions.zig").ComposerActions;
pub const ContentArea = @import("content_area.zig").ContentArea;
pub const DictationModelSelector = @import("dictation_model_selector.zig").DictationModelSelector;
pub const HistoryPanel = @import("history_panel.zig").HistoryPanel;
pub const HistoryToggle = @import("history_toggle.zig").HistoryToggle;
pub const InputArea = @import("input_area.zig").InputArea;
pub const message = @import("message.zig");
pub const MicrophoneMeter = @import("microphone_meter.zig").MicrophoneMeter;
pub const MicrophoneSettings = @import("microphone_settings.zig").MicrophoneSettings;
pub const ModelSelector = @import("model_selector.zig").ModelSelector;
pub const PulseDot = @import("pulse_dot.zig").PulseDot;
pub const RecordButton = @import("record_button.zig").RecordButton;
pub const SendButton = @import("send_button.zig").SendButton;
pub const SettingsPanel = @import("settings_panel.zig").SettingsPanel;
pub const SettingsToggle = @import("settings_toggle.zig").SettingsToggle;
pub const ThemeToggle = @import("theme_toggle.zig").ThemeToggle;
