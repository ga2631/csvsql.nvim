Output assets/demo.gif

Set Shell "bash"
Set FontSize 14
Set Width 1280
Set Height 640
Set Padding 14
Set WindowBar Colorful
Set Theme "GitHub Dark"
Set TypingSpeed 40ms

# Launch Neovim with a CSV file — auto-renders as a read-only table
Hide
Type "nvim -u demo/init.lua demo/sample.csv"
Enter
Sleep 1.5s
Show

# 1. Show auto-rendered table with 48-char ellipsis & zebra striping
Sleep 2s

# 2. Scroll down to showcase locked sticky header + CursorLine
Down 12
Sleep 1.8s
Type "gg"
Sleep 0.6s

# 3. Open SQL scratch editor split (gs) and run GROUP BY SQL query
Type "gs"
Sleep 0.8s
Type "ggdGi"
Type "SELECT region, COUNT(*) AS orders, ROUND(SUM(amount), 2) AS revenue"
Enter
Type "FROM data"
Enter
Type "WHERE status = 'paid'"
Enter
Type "GROUP BY region"
Enter
Type "ORDER BY revenue DESC"
Escape
Sleep 0.6s
Enter
Sleep 2.5s

# Close SQL split
Type "q"
Sleep 0.8s

# 4. Run SUMMARIZE data (gS) for instant column statistics
Type "gS"
Sleep 2.5s

# 5. Reset back to full table (gR)
Type "gR"
Sleep 1.5s

Hide
Type ":qa!"
Enter
