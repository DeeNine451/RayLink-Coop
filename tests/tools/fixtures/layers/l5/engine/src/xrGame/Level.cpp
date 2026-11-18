// stock GSC file without hooks
void CLevel::frame()
{
	if (g_coop_headless) return;
	update_all(); // coop::anything in a comment is not a hook
}
