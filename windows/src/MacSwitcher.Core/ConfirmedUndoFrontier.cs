using System;

namespace MacSwitcher.Core;

public sealed class ConfirmedUndoFrontier
{
    private readonly string original;

    public ConfirmedUndoFrontier(string original) { this.original = original ?? throw new ArgumentNullException(nameof(original)); }

    public bool TryCurrentText(string value, out string? currentText)
    {
        currentText = null;
        if (value == null || !value.StartsWith(original, StringComparison.Ordinal)) return false;
        var start = original.Length;
        if (start == 0 || original[start - 1] != ' ')
        {
            var separator = value.IndexOf(' ', start);
            if (separator < 0) return true;
            start = separator + 1;
        }
        while (start < value.Length && value[start] == ' ') start++;
        if (start < value.Length) currentText = value.Substring(start);
        return true;
    }
}
