using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using MacSwitcher.Core;
using MacSwitcher.Windows.Storage;

namespace MacSwitcher.Windows.UI;

internal sealed class SettingsDialog : Form
{
    private readonly ConfigurationStore store;
    private readonly CheckBox enabled = new CheckBox { Text = "Включить обработку Shift", AutoSize = true };
    private readonly CheckBox automatic = new CheckBox { Text = "Исправлять раскладку автоматически", AutoSize = true };
    private readonly CheckBox russianPriority = new CheckBox { Text = "При неоднозначном слове предпочитать русский", AutoSize = true };
    private readonly CheckBox smartSelection = new CheckBox { Text = "Сохранять правильные слова в выделении", AutoSize = true };
    private readonly CheckBox startup = new CheckBox { Text = "Запускать вместе с Windows (только для этого пользователя)", AutoSize = true };
    private readonly NumericUpDown interval = new NumericUpDown { Minimum = 80, Maximum = 400, Increment = 10, Width = 90 };
    private readonly ComboBox language = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 145 };
    private readonly ComboBox entryType = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 190 };
    private readonly ListBox entries = new ListBox { Dock = DockStyle.Fill, IntegralHeight = false };
    private readonly TextBox newEntry = new TextBox { Dock = DockStyle.Fill, MaxLength = 512 };
    private readonly ListBox forcedWords = new ListBox { Dock = DockStyle.Fill, IntegralHeight = false };
    private readonly TextBox newForcedWord = new TextBox { Dock = DockStyle.Fill, MaxLength = 96 };
    private readonly Button addButton = new Button { Text = "Добавить", AutoSize = true };
    private readonly Button removeButton = new Button { Text = "Удалить выбранное", AutoSize = true };
    private readonly Button importButton = new Button { Text = "Импорт…", AutoSize = true };
    private readonly Button exportButton = new Button { Text = "Экспорт…", AutoSize = true };
    private readonly Button recoverButton = new Button { Text = "Сохранить проблемный файл в копию…", AutoSize = true, Visible = false };
    private readonly Button saveButton = new Button { Text = "Сохранить", DialogResult = DialogResult.None, AutoSize = true };
    private readonly Label storeState = new Label { AutoSize = true, ForeColor = Color.DarkSlateGray, MaximumSize = new Size(365, 48) };
    private bool discardPendingChanges;

    public SettingsDialog(ConfigurationStore store)
    {
        this.store = store;
        Text = "Настройки MacSwitcher";
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;
        MaximizeBox = false;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        ClientSize = new Size(580, 470);

        var tabs = new TabControl { Dock = DockStyle.Fill };
        var general = new TabPage("Основные");
        var generalPanel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(14), AutoScroll = true };
        generalPanel.Controls.Add(enabled);
        generalPanel.Controls.Add(automatic);
        generalPanel.Controls.Add(russianPriority);
        generalPanel.Controls.Add(smartSelection);
        generalPanel.Controls.Add(startup);
        var intervalRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        intervalRow.Controls.Add(new Label { Text = "Интервал двойного Shift, мс:", AutoSize = true, Padding = new Padding(0, 6, 8, 0) });
        intervalRow.Controls.Add(interval);
        generalPanel.Controls.Add(intervalRow);
        general.Controls.Add(generalPanel);

        var personal = new TabPage("Слова и исключения");
        var personalPanel = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 5, Padding = new Padding(8) };
        personalPanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        personalPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        personalPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        personalPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        personalPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        personalPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        personalPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        personalPanel.Controls.Add(new Label { Text = "Язык:", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 0);
        language.Items.AddRange(new object[] { "Русский", "Английский" });
        language.SelectedIndex = 0;
        personalPanel.Controls.Add(language, 1, 0);
        personalPanel.Controls.Add(new Label { Text = "Тип записи:", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 1);
        entryType.Items.AddRange(new object[] { "Личное слово", "Фраза-исключение" });
        entryType.SelectedIndex = 0;
        personalPanel.Controls.Add(entryType, 1, 1);
        personalPanel.Controls.Add(entries, 0, 2);
        personalPanel.SetColumnSpan(entries, 2);
        var inputRow = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2 };
        inputRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        inputRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        inputRow.Controls.Add(newEntry, 0, 0);
        addButton.Click += (_, _) => AddEntry();
        inputRow.Controls.Add(addButton, 1, 0);
        personalPanel.Controls.Add(inputRow, 0, 3);
        personalPanel.SetColumnSpan(inputRow, 2);
        var fileButtons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        removeButton.Click += (_, _) => RemoveEntry();
        importButton.Click += (_, _) => ImportEntries();
        exportButton.Click += (_, _) => ExportEntries();
        fileButtons.Controls.AddRange(new Control[] { removeButton, importButton, exportButton });
        personalPanel.Controls.Add(fileButtons, 0, 4);
        personalPanel.SetColumnSpan(fileButtons, 2);
        personal.Controls.Add(personalPanel);

        var forcedPage = new TabPage("Всегда исправлять");
        var forcedPanel = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Padding = new Padding(8) };
        forcedPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        forcedPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        forcedPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        forcedPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        forcedPanel.Controls.Add(new Label { Text = "Эти слова будут исправляться при точном совпадении у границы слова. Добавляйте только те варианты, которые действительно хотите исправлять.", AutoSize = true, MaximumSize = new Size(520, 0) }, 0, 0);
        forcedPanel.Controls.Add(forcedWords, 0, 1);
        var forcedInputRow = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2 };
        forcedInputRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        forcedInputRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        forcedInputRow.Controls.Add(newForcedWord, 0, 0);
        var addForced = new Button { Text = "Добавить", AutoSize = true };
        addForced.Click += (_, _) => AddForcedWord();
        forcedInputRow.Controls.Add(addForced, 1, 0);
        forcedPanel.Controls.Add(forcedInputRow, 0, 2);
        var removeForced = new Button { Text = "Удалить выбранное", AutoSize = true, Anchor = AnchorStyles.Left };
        removeForced.Click += (_, _) => { if (forcedWords.SelectedItem != null) forcedWords.Items.Remove(forcedWords.SelectedItem); };
        forcedPanel.Controls.Add(removeForced, 0, 3);
        forcedPage.Controls.Add(forcedPanel);

        tabs.TabPages.Add(general);
        tabs.TabPages.Add(personal);
        tabs.TabPages.Add(forcedPage);
        var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 110, Padding = new Padding(8), FlowDirection = FlowDirection.RightToLeft };
        saveButton.Click += (_, _) => Save();
        recoverButton.Click += (_, _) => RecoverUnreadableFiles();
        var cancelButton = new Button { Text = "Отмена", DialogResult = DialogResult.None, AutoSize = true };
        cancelButton.Click += (_, _) =>
        {
            discardPendingChanges = true;
            DialogResult = DialogResult.Cancel;
            Close();
        };
        bottom.Controls.Add(saveButton);
        bottom.Controls.Add(cancelButton);
        bottom.Controls.Add(recoverButton);
        bottom.Controls.Add(storeState);
        Controls.Add(tabs);
        Controls.Add(bottom);
        AcceptButton = saveButton;
        CancelButton = cancelButton;
        FormClosing += OnFormClosing;

        enabled.Checked = store.Settings.Enabled;
        automatic.Checked = store.Settings.AutomaticCorrection;
        russianPriority.Checked = store.Settings.RussianPriority;
        smartSelection.Checked = store.Settings.SmartSelection;
        startup.Checked = store.Settings.StartWithWindows;
        interval.Value = store.Settings.DoubleShiftMilliseconds;
        forcedWords.Items.AddRange(store.Settings.AlwaysConvertWords.Cast<object>().ToArray());
        saveButton.Enabled = store.CanSaveSettings;
        addButton.Enabled = removeButton.Enabled = importButton.Enabled = store.CanSavePersonal;
        exportButton.Enabled = store.CanSavePersonal;
        recoverButton.Visible = !String.IsNullOrWhiteSpace(store.SettingsProblem) || !String.IsNullOrWhiteSpace(store.PersonalProblem);
        language.SelectedIndexChanged += (_, _) => RefreshEntries();
        entryType.SelectedIndexChanged += (_, _) => RefreshEntries();
        storeState.Text = String.Join("  ", new[] { store.SettingsProblem, store.PersonalProblem }.Where(x => !String.IsNullOrWhiteSpace(x)));
        if (String.IsNullOrWhiteSpace(storeState.Text)) storeState.Text = "Личный словарь сохраняется сразу.";
        RefreshEntries();
    }

    private void Save()
    {
        if (!PersistSettings()) return;
        DialogResult = DialogResult.OK;
        Close();
    }

    private bool PersistSettings()
    {
        try
        {
            var settings = new AppSettings
            {
                Enabled = enabled.Checked,
                AutomaticCorrection = automatic.Checked,
                RussianPriority = russianPriority.Checked,
                SmartSelection = smartSelection.Checked,
                StartWithWindows = startup.Checked,
                DoubleShiftMilliseconds = Decimal.ToInt32(interval.Value),
                ExcludedApplications = store.Settings.ExcludedApplications.ToArray(),
                AlwaysConvertWords = forcedWords.Items.Cast<string>().ToArray()
            };
            store.SaveSettings(settings);
            return true;
        }
        catch (Exception)
        {
            MessageBox.Show("Настройки не сохранены. Проверьте доступ к локальным файлам приложения или сначала восстановите повреждённый файл.", "Не удалось сохранить настройки", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
    }

    private bool SettingsAreDirty()
    {
        var current = store.Settings;
        return enabled.Checked != current.Enabled || automatic.Checked != current.AutomaticCorrection ||
            russianPriority.Checked != current.RussianPriority || smartSelection.Checked != current.SmartSelection ||
            startup.Checked != current.StartWithWindows || Decimal.ToInt32(interval.Value) != current.DoubleShiftMilliseconds ||
            !forcedWords.Items.Cast<string>().SequenceEqual(current.AlwaysConvertWords, StringComparer.Ordinal);
    }

    private void OnFormClosing(object? sender, FormClosingEventArgs e)
    {
        if (discardPendingChanges || !SettingsAreDirty()) return;
        var choice = MessageBox.Show("Сохранить изменённые настройки перед закрытием? Выберите «Нет», чтобы отбросить их, или «Отмена», чтобы продолжить редактирование.",
            "Несохранённые настройки", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
        if (choice == DialogResult.Cancel) { e.Cancel = true; return; }
        if (choice == DialogResult.Yes)
        {
            if (!PersistSettings()) { e.Cancel = true; return; }
            DialogResult = DialogResult.OK;
        }
        else DialogResult = DialogResult.Cancel;
    }

    private void AddEntry()
    {
        if (String.IsNullOrWhiteSpace(newEntry.Text)) return;
        try
        {
            if (entryType.SelectedIndex == 0) store.AddWord(newEntry.Text.Trim(), LanguageCode());
            else store.AddException(newEntry.Text.Trim(), LanguageCode());
            newEntry.Clear();
            RefreshEntries();
        }
        catch (Exception) { MessageBox.Show(store.CanSavePersonal ? "Запись не добавлена. Проверьте, что это слово или фраза без управляющих символов." : store.PersonalProblem, "Не удалось добавить запись", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    private void RemoveEntry()
    {
        if (entries.SelectedItem == null) return;
        try
        {
            var value = entries.SelectedItem.ToString()!;
            if (entryType.SelectedIndex == 0) store.RemoveWord(value, LanguageCode());
            else store.RemoveException(value, LanguageCode());
            RefreshEntries();
        }
        catch (Exception) { MessageBox.Show(store.CanSavePersonal ? "Запись не удалена. Попробуйте ещё раз." : store.PersonalProblem, "Не удалось удалить запись", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    private void AddForcedWord()
    {
        var value = newForcedWord.Text.Trim();
        if (value.Length == 0 || forcedWords.Items.Cast<string>().Contains(value, StringComparer.OrdinalIgnoreCase)) return;
        forcedWords.Items.Add(value);
        newForcedWord.Clear();
    }

    private void ImportEntries()
    {
        using var picker = new OpenFileDialog { Filter = "Файл личного словаря (*.json)|*.json|Все файлы (*.*)|*.*", CheckFileExists = true };
        if (picker.ShowDialog(this) != DialogResult.OK) return;
        if (MessageBox.Show("Импорт заменит текущие личные слова и фразы-исключения. Продолжить?", "Заменить личный словарь?", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        try { store.ImportPersonal(picker.FileName); RefreshEntries(); }
        catch (Exception) { MessageBox.Show("Импорт не выполнен. Текущий словарь сохранён. Проверьте, что выбран файл MacSwitcher JSON и в нём нет повреждённых или слишком длинных записей.", "Импорт словаря", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    private void ExportEntries()
    {
        using var picker = new SaveFileDialog { Filter = "Файл личного словаря (*.json)|*.json", DefaultExt = "json", AddExtension = true, FileName = "MacSwitcher-personal.json" };
        if (picker.ShowDialog(this) != DialogResult.OK) return;
        try { store.ExportPersonal(picker.FileName); }
        catch (Exception) { MessageBox.Show("Не удалось сохранить файл словаря. Проверьте доступ к выбранной папке и свободное место.", "Экспорт словаря", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    private void RecoverUnreadableFiles()
    {
        var answer = MessageBox.Show("MacSwitcher не смог проверить один или несколько локальных файлов. Продолжить только после перемещения проблемных файлов в резервные копии? Их содержимое сохранится без изменений, а новые пустые настройки или словарь создадутся отдельно.",
            "Сохранить резервную копию?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
        if (answer != DialogResult.Yes) return;
        try
        {
            var preserved = store.RecoverUnreadableFiles();
            enabled.Checked = store.Settings.Enabled;
            automatic.Checked = store.Settings.AutomaticCorrection;
            russianPriority.Checked = store.Settings.RussianPriority;
            smartSelection.Checked = store.Settings.SmartSelection;
            startup.Checked = store.Settings.StartWithWindows;
            interval.Value = store.Settings.DoubleShiftMilliseconds;
            forcedWords.Items.Clear();
            forcedWords.Items.AddRange(store.Settings.AlwaysConvertWords.Cast<object>().ToArray());
            saveButton.Enabled = store.CanSaveSettings;
            addButton.Enabled = removeButton.Enabled = importButton.Enabled = store.CanSavePersonal;
        exportButton.Enabled = store.CanSavePersonal;
            recoverButton.Visible = !String.IsNullOrWhiteSpace(store.SettingsProblem) || !String.IsNullOrWhiteSpace(store.PersonalProblem);
            storeState.Text = "Резервные копии сохранены: " + String.Join(", ", preserved.Select(Path.GetFileName));
            RefreshEntries();
            MessageBox.Show("Проблемные файлы перемещены в резервные копии. Теперь можно импортировать личный словарь или создать новые записи.", "Локальные данные восстановлены", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception) { MessageBox.Show("Не удалось завершить восстановление. Исходные данные остаются на диске; проверьте доступ к папке приложения и повторите попытку.", "Восстановление данных", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    private void RefreshEntries()
    {
        entries.Items.Clear();
        var snapshot = store.Personal.ExportSnapshot();
        string[] values;
        if (LanguageCode() == "ru")
            values = entryType.SelectedIndex == 0 ? snapshot.RussianWords : snapshot.RussianPhraseExceptions;
        else
            values = entryType.SelectedIndex == 0 ? snapshot.EnglishWords : snapshot.EnglishPhraseExceptions;
        entries.Items.AddRange(values.Cast<object>().ToArray());
    }

    private string LanguageCode() => language.SelectedIndex == 0 ? "ru" : "en";
}
