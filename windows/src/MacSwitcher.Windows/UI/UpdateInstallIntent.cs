namespace MacSwitcher.Windows.UI;

/// <summary>One-use consent gate for launching an already verified installer.</summary>
public sealed class UpdateInstallIntent
{
    private bool granted;

    public void Grant() => granted = true;

    public void Cancel() => granted = false;

    public bool TryConsume()
    {
        if (!granted) return false;
        granted = false;
        return true;
    }
}
