using System;
using System.Drawing;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using MacSwitcher.Core;
using MacSwitcher.Windows.Runtime;
using MacSwitcher.Windows.Storage;
using MacSwitcher.Windows.Updates;

namespace MacSwitcher.Windows.UI;

public sealed class SwitcherContext : ApplicationContext
{
    private readonly WindowsSwitcherRuntime runtime;
    private readonly ConfigurationStore store;
    private readonly NotifyIcon tray;
    private readonly ToolStripMenuItem statusItem;
    private readonly ToolStripMenuItem enabledItem;
    private readonly ToolStripMenuItem automaticItem;
    private readonly ToolStripMenuItem russianItem;
    private readonly ToolStripMenuItem englishItem;
    private readonly ToolStripMenuItem updatesItem;
    private readonly ToolStripMenuItem installDownloadedItem;
    private readonly ToolStripMenuItem recoveryItem;
    private readonly Control dispatcher = new Control();
    private readonly WindowsUpdateService updateService;
    private readonly UpdateInstallIntent installIntent = new UpdateInstallIntent();
    private string? pendingInstallerPath;
    private bool updateInProgress;
    private bool closing;

    public SwitcherContext(WindowsSwitcherRuntime runtime, ConfigurationStore store, bool showSettings)
    {
        this.runtime = runtime ?? throw new ArgumentNullException(nameof(runtime));
        this.store = store ?? throw new ArgumentNullException(nameof(store));
        var executable = Assembly.GetEntryAssembly()?.Location;
        var currentBuild = String.IsNullOrEmpty(executable) ? 1 : FileVersionInfo.GetVersionInfo(executable).FileBuildPart;
        updateService = new WindowsUpdateService(currentBuild > 0 ? currentBuild : 1);
        dispatcher.CreateControl();
        _ = dispatcher.Handle;

        var menu = new ContextMenuStrip();
        menu.Opening += (_, _) => RefreshMenu();
        statusItem = new ToolStripMenuItem("Запуск…") { Enabled = false };
        enabledItem = new ToolStripMenuItem("Включено") { CheckOnClick = true };
        enabledItem.Click += (_, _) => UpdateSettings(s => s.Enabled = enabledItem.Checked);
        automaticItem = new ToolStripMenuItem("Исправлять автоматически") { CheckOnClick = true };
        automaticItem.Click += (_, _) => UpdateSettings(s => s.AutomaticCorrection = automaticItem.Checked);
        var layouts = new ToolStripMenuItem("Раскладка");
        russianItem = new ToolStripMenuItem("Русская") { CheckOnClick = false };
        englishItem = new ToolStripMenuItem("Английская") { CheckOnClick = false };
        russianItem.Click += (_, _) => SwitchLayout("ru");
        englishItem.Click += (_, _) => SwitchLayout("en");
        layouts.DropDownItems.AddRange(new ToolStripItem[] { russianItem, englishItem });
        layouts.DropDownItems.Add(new ToolStripSeparator());
        var languageSettings = new ToolStripMenuItem("Добавить раскладку Windows…");
        languageSettings.Click += (_, _) => OpenWindowsLanguageSettings();
        layouts.DropDownItems.Add(languageSettings);
        var settingsItem = new ToolStripMenuItem("Настройки и словарь…");
        settingsItem.Click += (_, _) => ShowSettings();
        recoveryItem = new ToolStripMenuItem("Исходные тексты после сбоя…");
        recoveryItem.Click += (_, _) => ShowRecoveryOriginals();
        updatesItem = new ToolStripMenuItem("Проверить обновления Windows…");
        updatesItem.Click += async (_, _) => await CheckForUpdatesAsync();
        installDownloadedItem = new ToolStripMenuItem("Установить проверенное обновление…") { Visible = false };
        installDownloadedItem.Click += (_, _) => ConfirmInstallPendingUpdate();
        var exitItem = new ToolStripMenuItem("Выход");
        exitItem.Click += (_, _) => ExitSafely();
        menu.Items.AddRange(new ToolStripItem[] { statusItem, new ToolStripSeparator(), enabledItem, automaticItem, layouts, settingsItem, recoveryItem, updatesItem, installDownloadedItem, new ToolStripSeparator(), exitItem });

        tray = new NotifyIcon { Text = "MacSwitcher запускается", Visible = true, ContextMenuStrip = menu, Icon = LoadIcon() };
        tray.DoubleClick += (_, _) => ShowSettings();
        runtime.StatusChanged += OnStatusChanged;
        runtime.CorrectionApplied += OnCorrectionApplied;
        runtime.CorrectionUndone += OnCorrectionUndone;
        RefreshMenu();

        if (showSettings)
        {
            if (store.LearningExplanationPending) ShowFirstRun();
            ShowSettings();
        }
    }

    private void OnStatusChanged(RuntimeStatus status)
    {
        Dispatch(() =>
        {
            if (!store.CanSaveSettings || !store.CanSavePersonal)
                SetStatus("Обработка текста приостановлена: есть проблемный файл. Откройте настройки для сохранения копии и восстановления данных.");
            else if (!store.Settings.Enabled)
                SetStatus("MacSwitcher приостановлен. Включите его в меню значка.");
            else
                SetStatus(status?.Message ?? "Статус недоступен");
            if (status?.NeedsAdministrator == true)
                SetStatus("Текущее окно запущено от имени администратора. Для работы с ним запустите MacSwitcher от имени администратора.");
        });
    }

    private void OnCorrectionApplied(CorrectionNotice notice)
    {
        // Text content is deliberately not shown, saved, or logged.
        store.Adaptive.Submit(new AdaptiveEvent(notice.OccurrenceId,notice.Original,notice.Replacement,
            notice.Origin,notice.Action,notice.SourceConfirmed,notice.LearningGeneration));
        Dispatch(() => SetStatus("Текст исправлен."));
    }

    private void OnCorrectionUndone(CorrectionNotice notice)
    {
        store.Adaptive.Submit(new AdaptiveEvent(notice.OccurrenceId,notice.Original,notice.Replacement,
            notice.Origin,notice.Action,notice.SourceConfirmed,notice.LearningGeneration));
        Dispatch(() => SetStatus("Последнее исправление отменено."));
    }

    private void SetStatus(string message)
    {
        statusItem.Text = SafeMenuText(message);
        tray.Text = SafeNotifyText(message);
    }

    private static string SafeMenuText(string value) => value.Length > 120 ? value.Substring(0, 117) + "…" : value;
    private static string SafeNotifyText(string value) => value.Length > 63 ? value.Substring(0, 60) + "…" : value;

    private void RefreshMenu()
    {
        enabledItem.Checked = store.Settings.Enabled;
        automaticItem.Checked = store.Settings.AutomaticCorrection;
        recoveryItem.Enabled = runtime.HasRecoveryOriginals;
        russianItem.Checked = string.Equals(runtime.CurrentLayoutLanguage, "ru", StringComparison.OrdinalIgnoreCase);
        englishItem.Checked = string.Equals(runtime.CurrentLayoutLanguage, "en", StringComparison.OrdinalIgnoreCase);
    }

    private void UpdateSettings(Action<AppSettings> change)
    {
        var next = Clone(store.Settings);
        change(next);
        try
        {
            store.SaveSettings(next);
            runtime.ApplySettings(next);
            RefreshMenu();
        }
        catch (Exception)
        {
            RefreshMenu();
            var message = !store.CanSaveSettings ? store.SettingsProblem : "Не удалось сохранить настройки. Проверьте доступ к локальной папке приложения и повторите попытку.";
            MessageBox.Show(message, "MacSwitcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void SwitchLayout(string language)
    {
        if (!runtime.TrySwitchLayout(language)) return;
        RefreshMenu();
    }

    private void OpenWindowsLanguageSettings()
    {
        try
        {
            var version = Environment.OSVersion.Version;
            var start = version.Major >= 10
                ? new ProcessStartInfo("ms-settings:regionlanguage") { UseShellExecute = true }
                : version.Major > 6 || version.Major == 6 && version.Minor >= 2
                    ? new ProcessStartInfo("control.exe", "/name Microsoft.Language") { UseShellExecute = true }
                    : new ProcessStartInfo("control.exe", "intl.cpl") { UseShellExecute = true };
            Process.Start(start);
        }
        catch (Exception)
        {
            MessageBox.Show("Не удалось открыть параметры языка Windows. Найдите раздел «Язык» или «Клавиатура» в параметрах Windows и добавьте нужную раскладку.",
                "Раскладки Windows", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    private void ShowFirstRun()
    {
        MessageBox.Show("MacSwitcher работает в области уведомлений. Один Shift меняет раскладку, два быстрых нажатия Shift исправляют последнее слово или выделение.\n\nЗапоминание исправлений включено: после двух независимых подтверждений одного слова MacSwitcher сохранит только пару слов и предпочитаемый вариант в локальном файле. Полный текст и клавиши не сохраняются. Это можно выключить и удалить правила в настройках.",
            "Добро пожаловать в MacSwitcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
        try { store.SaveSettings(Clone(store.Settings)); } catch { /* The explanation repeats if settings cannot be saved. */ }
    }

    private void ShowSettings()
    {
        using var dialog = new SettingsDialog(store);
        if (dialog.ShowDialog() == DialogResult.OK)
        {
            runtime.ApplySettings(store.Settings);
            RefreshMenu();
        }
    }

    public void ShowSettingsFromDuplicate() => Dispatch(ShowSettings);

    public void RequestQuitFromDuplicate() => Dispatch(() => ExitSafely());

    private void ShowRecoveryOriginals()
    {
        using var dialog = new RecoveryOriginalsDialog(runtime);
        dialog.ShowDialog();
    }

    public void LaunchPendingInstaller()
    {
        if (pendingInstallerPath == null || !installIntent.TryConsume()) return;
        try
        {
            updateService.LaunchVerifiedInstaller(pendingInstallerPath);
            pendingInstallerPath = null;
        }
        catch (Exception)
        {
            MessageBox.Show("Установщик не запущен: повторная проверка файла не пройдена. Текущая версия не менялась; откройте MacSwitcher и повторите проверку обновлений.",
                "Обновление MacSwitcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private async Task CheckForUpdatesAsync()
    {
        if (updateInProgress) return;
        updateInProgress = true;
        try
        {
            SetStatus("Проверяю подписанные обновления Windows…");
            UpdateManifest? update;
            try { update = await updateService.CheckAsync(); }
            catch (UpdateNotNewerException)
            {
                MessageBox.Show("Установлена последняя подписанная версия MacSwitcher.", "Обновления MacSwitcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            catch (Exception)
            {
                var fallback = MessageBox.Show("Не удалось проверить подписанную ленту обновлений. Открыть страницу выпусков MacSwitcher для ручной проверки?",
                    "Обновления MacSwitcher", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                if (fallback == DialogResult.Yes) OpenReleasesPage();
                return;
            }
            if (update == null)
            {
                var fallback = MessageBox.Show("Подписанная лента обновлений пока недоступна. Открыть страницу выпусков MacSwitcher для ручной проверки?",
                    "Обновления MacSwitcher", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                if (fallback == DialogResult.Yes) OpenReleasesPage();
                return;
            }
            var download = MessageBox.Show("Доступно обновление MacSwitcher " + update.Version + ". Скачать проверенный установщик?",
                "Обновление MacSwitcher", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (download != DialogResult.Yes) return;

            SetStatus("Скачиваю и проверяю установщик…");
            var installer = await updateService.DownloadInstallerAsync(update, progress: (received, total) =>
                Dispatch(() => SetStatus(total > 0 ? "Скачивание обновления: " + (received * 100 / total) + "%" : "Скачиваю обновление…")));
            pendingInstallerPath = installer;
            installDownloadedItem.Visible = true;
            updatesItem.Enabled = false;
            var install = MessageBox.Show("Файл обновления проверен по подписанным метаданным и контрольной сумме. Запустить установщик сейчас? Приложение закроется после сохранения исходного текста восстановления, если он есть.",
                "Установщик проверен", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (install == DialogResult.Yes)
                ConfirmInstallPendingUpdate(false);
            else SetStatus("Установщик проверен и сохранён. Выберите «Установить проверенное обновление» в меню значка, когда будете готовы.");
        }
        catch (Exception)
        {
            var fallback = MessageBox.Show("Обновление не выполнено. Текущая версия MacSwitcher продолжает работать. Открыть страницу выпусков для ручной проверки?",
                "Обновление MacSwitcher", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (fallback == DialogResult.Yes) OpenReleasesPage();
        }
        finally { updateInProgress = false; }
    }

    private void ConfirmInstallPendingUpdate(bool askConfirmation = true)
    {
        if (pendingInstallerPath == null) return;
        if (askConfirmation)
        {
            var install = MessageBox.Show("Запустить проверенный установщик и закрыть MacSwitcher? Если есть исходный текст восстановления, приложение сначала предложит сохранить его в закрытую локальную папку.",
                "Установить обновление?", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (install != DialogResult.Yes) return;
        }
        if (!ExitSafely(preserveInstallIntent: true))
        {
            installIntent.Cancel();
            SetStatus("Выход отменён; проверенный установщик остался доступен в меню.");
            return;
        }
        installIntent.Grant();
    }

    private void OpenReleasesPage()
    {
        try
        {
            Process.Start(new ProcessStartInfo("https://github.com/alexfisenkov/MacSwitcher/releases") { UseShellExecute = true });
            SetStatus("Открыта страница выпусков MacSwitcher.");
        }
        catch (Exception) { MessageBox.Show("Не удалось открыть страницу выпусков. Проверьте, что в Windows выбран браузер.", "MacSwitcher", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    private bool ExitSafely(bool preserveInstallIntent = false)
    {
        if (!preserveInstallIntent) installIntent.Cancel();
        if (closing) return true;
        if (runtime.HasRecoveryOriginals)
        {
            var result = MessageBox.Show("Есть исходный текст, сохранённый только в памяти. Сохранить его в закрытую локальную папку восстановления и выйти? При ответе «Нет» выход будет отменён.",
                "Сохранить исходный текст?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (result != DialogResult.Yes) { installIntent.Cancel(); return false; }
            if (result == DialogResult.Yes)
            {
                var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MacSwitcherWindows", "Recovery");
                try { runtime.ExportRecovery(directory); }
                catch (Exception) { installIntent.Cancel(); MessageBox.Show("Не удалось сохранить исходный текст в закрытую локальную папку. Выход отменён; приложение продолжает работу.", "MacSwitcher", MessageBoxButtons.OK, MessageBoxIcon.Error); return false; }
            }
        }
        closing = true;
        tray.Visible = false;
        tray.Dispose();
        runtime.Dispose();
        ExitThread();
        return true;
    }

    private void Dispatch(Action action)
    {
        if (closing || dispatcher.IsDisposed || !dispatcher.IsHandleCreated) return;
        try { dispatcher.BeginInvoke(action); } catch (InvalidOperationException) { }
    }

    protected override void ExitThreadCore()
    {
        if (!closing) { ExitSafely(); return; }
        base.ExitThreadCore();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            runtime.StatusChanged -= OnStatusChanged;
            runtime.CorrectionApplied -= OnCorrectionApplied;
            runtime.CorrectionUndone -= OnCorrectionUndone;
            tray.Dispose();
            updateService.Dispose();
            dispatcher.Dispose();
        }
        base.Dispose(disposing);
    }

    private static AppSettings Clone(AppSettings value) => new AppSettings
    {
        Enabled = value.Enabled,
        AutomaticCorrection = value.AutomaticCorrection,
        RememberCorrections = value.RememberCorrections,
        RussianPriority = value.RussianPriority,
        StartWithWindows = value.StartWithWindows,
        DoubleShiftMilliseconds = value.DoubleShiftMilliseconds,
        ExcludedApplications = value.ExcludedApplications.ToArray(),
        AlwaysConvertWords = value.AlwaysConvertWords.ToArray(),
        SmartSelection = value.SmartSelection
    };

    private static Icon LoadIcon()
    {
        var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "MacSwitcher.ico");
        return File.Exists(path) ? new Icon(path) : SystemIcons.Application;
    }
}
