using System;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using MacSwitcher.Windows.Runtime;

namespace MacSwitcher.Windows.UI;

internal sealed class RecoveryOriginalsDialog : Form
{
    private readonly WindowsSwitcherRuntime runtime;
    private readonly ListBox items = new ListBox { Dock = DockStyle.Fill, DisplayMember = nameof(RecoveryOriginalInfo.Label), IntegralHeight = false };
    private readonly Button copyButton = new Button { Text = "Скопировать исходный текст", AutoSize = true };
    private readonly Button exportButton = new Button { Text = "Экспортировать все…", AutoSize = true };

    public RecoveryOriginalsDialog(WindowsSwitcherRuntime runtime)
    {
        this.runtime = runtime;
        Text = "Исходные тексты после сбоя";
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MinimizeBox = false;
        MaximizeBox = false;
        ClientSize = new System.Drawing.Size(540, 310);

        var description = new Label
        {
            Dock = DockStyle.Top,
            Height = 104,
            Text = "Исходный текст хранится только в памяти приложения. Выберите запись, чтобы скопировать её в буфер обмена, или экспортируйте все записи в закрытую локальную папку. Чтобы попробовать восстановить текст в исходном поле, вернитесь туда и выделите всё содержимое поля целиком. Это сработает, только если текущий текст совпадает с последним наблюдением приложения; иначе скопируйте или экспортируйте запись.",
            Padding = new Padding(8)
        };
        var footer = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 48, Padding = new Padding(6), FlowDirection = FlowDirection.RightToLeft };
        var closeButton = new Button { Text = "Закрыть", DialogResult = DialogResult.Cancel, AutoSize = true };
        copyButton.Click += (_, _) => CopySelected();
        exportButton.Click += (_, _) => ExportAll();
        footer.Controls.Add(closeButton);
        footer.Controls.Add(exportButton);
        footer.Controls.Add(copyButton);
        Controls.Add(items);
        Controls.Add(description);
        Controls.Add(footer);
        CancelButton = closeButton;
        RefreshItems();
    }

    private void RefreshItems()
    {
        items.Items.Clear();
        items.Items.AddRange(runtime.GetRecoveryOriginalsSnapshot().Cast<object>().ToArray());
        if (items.Items.Count > 0) items.SelectedIndex = 0;
        copyButton.Enabled = items.Items.Count > 0;
        exportButton.Enabled = items.Items.Count > 0;
    }

    private void CopySelected()
    {
        if (items.SelectedItem is not RecoveryOriginalInfo selected) return;
        try
        {
            Clipboard.SetText(selected.Original);
            MessageBox.Show("Исходный текст скопирован в буфер обмена. Вставьте его в нужное приложение.", "Исходный текст скопирован", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception)
        {
            MessageBox.Show("Не удалось скопировать исходный текст. Проверьте, что буфер обмена доступен, и повторите попытку.", "Копирование не выполнено", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void ExportAll()
    {
        if (MessageBox.Show("Экспортировать все исходные тексты в закрытую локальную папку восстановления?", "Экспорт исходных текстов", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MacSwitcherWindows", "Recovery");
        try
        {
            var path = runtime.ExportRecovery(directory);
            MessageBox.Show("Исходные тексты экспортированы в закрытую локальную папку. Имя файла: " + Path.GetFileName(path), "Экспорт завершён", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception)
        {
            MessageBox.Show("Экспорт не выполнен. Исходные тексты остаются в памяти приложения; попробуйте ещё раз.", "Экспорт не выполнен", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
