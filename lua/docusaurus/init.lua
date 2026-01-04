local M = {}

local config = {
	-- Default configuration options
	partials_dirs = { "_partials", "_fragments", "_code" },
	components_dir = nil, -- Will default to ./src/components if not set
	allowed_site_paths = { "^docs/_" }, -- Any underscore directory under docs/
	-- External repos configuration
	external_repos_dir = nil, -- Defaults to XDG data dir
	docs_branch_name = "docs-updates", -- Branch name for documentation changes
}

-- Module state for external repos
local state = {
	active_repo = nil, -- Currently selected external repo
}

function M.setup(user_config)
	-- Merge user config with defaults
	config = vim.tbl_deep_extend("force", config, user_config or {})
end

-- ========================================
-- External Repos Helper Functions
-- ========================================

-- Get XDG data directory for storing external repos
local function get_xdg_data_dir()
	if config.external_repos_dir then
		return vim.fn.expand(config.external_repos_dir)
	end
	return vim.fn.stdpath("data") .. "/docusaurus/repos"
end

-- Get path to repos registry file
local function get_registry_path()
	return get_xdg_data_dir() .. "/repos.yaml"
end

-- Parse simple YAML format for repos registry
-- Supports format:
-- repos:
--   - name: value
--     git_url: value
--     docusaurus_root: value
--     cloned_at: value
local function parse_yaml(content)
	local registry = { repos = {} }
	if not content or content == "" then
		return registry
	end

	local current_repo = nil
	local in_repos_list = false

	for line in content:gmatch("[^\r\n]+") do
		-- Skip empty lines and comments
		if line:match("^%s*$") or line:match("^%s*#") then
			-- skip
		elseif line:match("^repos:%s*$") then
			in_repos_list = true
		elseif in_repos_list then
			-- Check for new list item (starts with "  - ")
			local first_key, first_value = line:match("^%s*%-%s*([%w_]+):%s*(.*)$")
			if first_key then
				-- Save previous repo if exists
				if current_repo then
					table.insert(registry.repos, current_repo)
				end
				-- Start new repo
				current_repo = {}
				-- Remove quotes from value if present
				first_value = first_value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
				current_repo[first_key] = first_value
			else
				-- Check for continuation key-value pair (starts with spaces, no dash)
				local key, value = line:match("^%s+([%w_]+):%s*(.*)$")
				if key and current_repo then
					-- Remove quotes from value if present
					value = value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
					current_repo[key] = value
				end
			end
		end
	end

	-- Don't forget the last repo
	if current_repo then
		table.insert(registry.repos, current_repo)
	end

	return registry
end

-- Serialize registry to YAML format
local function serialize_yaml(registry)
	local lines = { "repos:" }

	for _, repo in ipairs(registry.repos or {}) do
		-- First field with dash
		table.insert(lines, string.format("  - name: %s", repo.name or ""))
		-- Remaining fields indented
		if repo.git_url then
			table.insert(lines, string.format("    git_url: %s", repo.git_url))
		end
		if repo.docusaurus_root then
			table.insert(lines, string.format("    docusaurus_root: %s", repo.docusaurus_root))
		end
		if repo.cloned_at then
			table.insert(lines, string.format('    cloned_at: "%s"', repo.cloned_at))
		end
	end

	return table.concat(lines, "\n") .. "\n"
end

-- Load repos registry from disk
local function load_repos_registry()
	local registry_path = get_registry_path()
	if vim.fn.filereadable(registry_path) ~= 1 then
		return { repos = {} }
	end

	local lines = vim.fn.readfile(registry_path)
	local content = table.concat(lines, "\n")

	local ok, result = pcall(parse_yaml, content)
	if not ok or not result then
		return { repos = {} }
	end

	return result
end

-- Save repos registry to disk
local function save_repos_registry(registry)
	local registry_path = get_registry_path()
	local dir = vim.fn.fnamemodify(registry_path, ":h")

	-- Ensure directory exists
	if vim.fn.isdirectory(dir) ~= 1 then
		vim.fn.mkdir(dir, "p")
	end

	local content = serialize_yaml(registry)
	local file = io.open(registry_path, "w")
	if file then
		file:write(content)
		file:close()
		return true
	end
	return false
end

-- Get full path to a cloned repo
local function get_repo_path(repo_name)
	return get_xdg_data_dir() .. "/" .. repo_name
end

-- Find repo in registry by name
local function find_repo_by_name(name)
	local registry = load_repos_registry()
	for _, repo in ipairs(registry.repos) do
		if repo.name == name then
			return repo
		end
	end
	return nil
end

-- Get default branch of a repository
local function get_default_branch(repo_path)
	local cmd = string.format("cd '%s' && git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}'", repo_path)
	local result = vim.fn.system(cmd):gsub("%s+", "")

	if vim.v.shell_error ~= 0 or result == "" then
		-- Fallback: try to detect from local refs
		local fallback_cmd = string.format("cd '%s' && git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'", repo_path)
		result = vim.fn.system(fallback_cmd):gsub("%s+", "")

		if result == "" then
			return "main" -- Default fallback
		end
	end

	return result
end

-- Get current branch of a repository
local function get_current_branch(repo_path)
	local cmd = string.format("cd '%s' && git branch --show-current", repo_path)
	local result = vim.fn.system(cmd):gsub("%s+", "")
	return result
end

-- Ensure docs-updates branch exists and is checked out
local function ensure_docs_branch(repo_path)
	local branch_name = config.docs_branch_name
	local current_branch = get_current_branch(repo_path)

	-- Already on the docs branch
	if current_branch == branch_name then
		return true, "Already on " .. branch_name .. " branch"
	end

	-- Check if branch exists
	local check_cmd = string.format("cd '%s' && git show-ref --verify --quiet refs/heads/%s", repo_path, branch_name)
	vim.fn.system(check_cmd)
	local branch_exists = vim.v.shell_error == 0

	if branch_exists then
		-- Checkout existing branch
		local checkout_cmd = string.format("cd '%s' && git checkout %s 2>&1", repo_path, branch_name)
		local output = vim.fn.system(checkout_cmd)
		if vim.v.shell_error ~= 0 then
			return false, "Failed to checkout " .. branch_name .. ": " .. output
		end
		return true, "Switched to " .. branch_name .. " branch"
	else
		-- Create new branch from default branch
		local default_branch = get_default_branch(repo_path)
		local create_cmd = string.format("cd '%s' && git checkout -b %s %s 2>&1", repo_path, branch_name, default_branch)
		local output = vim.fn.system(create_cmd)
		if vim.v.shell_error ~= 0 then
			return false, "Failed to create " .. branch_name .. " branch: " .. output
		end
		return true, "Created and switched to " .. branch_name .. " branch from " .. default_branch
	end
end

-- Derive repo name from git URL
local function derive_repo_name(git_url)
	-- Handle various git URL formats
	local name = git_url:match("([^/]+)%.git$")
		or git_url:match("([^/]+)$")
		or "repo"
	return name
end

-- ========================================
-- Version Context Functions
-- ========================================

-- Extract version context from file path
-- Returns:
--   { type="versioned", folder="vcluster_versioned_docs/version-0.20.x", project="vcluster" }
--   { type="main", project="vcluster" } (for vcluster/ main folder)
--   { type="non-versioned" } (for shared docs/ folder)
local function get_version_context(file_path, git_root)
	if not file_path or file_path == "" then
		return { type = "non-versioned" }
	end

	-- Make path relative to git root
	local relative_path = file_path
	if git_root and file_path:sub(1, #git_root) == git_root then
		relative_path = file_path:sub(#git_root + 2)
	end

	-- Pattern: <project>_versioned_docs/version-<version>/
	-- Examples: vcluster_versioned_docs/version-0.20.x/, platform_versioned_docs/version-4.4.0/
	local project = relative_path:match("^([^/]+)_versioned_docs/")
	local versioned_folder = relative_path:match("^([^/]+_versioned_docs/version%-[^/]+)")
	if project and versioned_folder then
		return {
			type = "versioned",
			folder = versioned_folder,
			project = project,
		}
	end

	-- Pattern: main project folder (vcluster/, platform/)
	-- These are the current/main version docs
	if relative_path:match("^vcluster/") then
		return {
			type = "main",
			project = "vcluster",
		}
	elseif relative_path:match("^platform/") then
		return {
			type = "main",
			project = "platform",
		}
	end

	return { type = "non-versioned" }
end

-- Check if path matches version context
-- Paths match if they are in:
-- 1. The same version folder (for versioned context)
-- 2. The same main project folder (for main context)
-- 3. Non-versioned root folders (docs/_partials/, docs/_fragments/, docs/_code/)
local function path_matches_context(path, context, git_root)
	if not path or path == "" then
		return false
	end

	-- Make path relative to git root
	local relative_path = path
	if git_root and path:sub(1, #git_root) == git_root then
		relative_path = path:sub(#git_root + 2)
	end

	-- Always include non-versioned root folders (docs/_partials/, etc.)
	for _, pattern in ipairs(config.allowed_site_paths) do
		if relative_path:match(pattern) then
			return true
		end
	end

	-- If no specific version/project context, show all
	if context.type == "non-versioned" then
		return true
	end

	-- If main project context (vcluster/, platform/), only show:
	-- - Files from the same project's main folder
	-- - NOT from versioned folders or other projects
	if context.type == "main" and context.project then
		-- Check if path is in same main project folder
		if relative_path:match("^" .. context.project .. "/") then
			return true
		end
		-- Exclude versioned folders and other projects
		return false
	end

	-- If versioned context, only show files from same version folder
	if context.type == "versioned" and context.folder then
		return relative_path:sub(1, #context.folder) == context.folder
	end

	return false
end

-- Function to recursively find all _partials directories in the repository
-- Optional: filter by version context
local function get_all_partials_dirs(version_context, git_root_param)
	local partials_dirs = {}

	-- Get git repository root
	local git_root = git_root_param or vim.fn.system("git rev-parse --show-toplevel"):gsub("%s+", "")

	if git_root == "" then
		print("Not inside a git repository.")
		return partials_dirs
	end

	local function scan_dir(dir)
		local entries = vim.fn.readdir(dir)
		for _, name in ipairs(entries) do
			local full_path = dir .. "/" .. name
			if vim.fn.isdirectory(full_path) == 1 then
				-- Check if directory name matches any of the configured partial dirs
				for _, partial_dir in ipairs(config.partials_dirs) do
					if name == partial_dir then
						-- Apply version context filtering if provided
						if not version_context or path_matches_context(full_path, version_context, git_root) then
							table.insert(partials_dirs, full_path)
						end
						break
					end
				end
				if name ~= "." and name ~= ".." and name ~= ".git" and name ~= "node_modules" then
					scan_dir(full_path)
				end
			end
		end
	end

	scan_dir(git_root)

	-- Sort partials: root docs folders first, then version-specific folders
	table.sort(partials_dirs, function(a, b)
		local a_rel = a:sub(#git_root + 2) -- Remove git root prefix
		local b_rel = b:sub(#git_root + 2)

		-- Check if paths match allowed_site_paths patterns (root docs folders)
		local a_is_root = false
		local b_is_root = false
		for _, pattern in ipairs(config.allowed_site_paths) do
			if a_rel:match(pattern) then
				a_is_root = true
			end
			if b_rel:match(pattern) then
				b_is_root = true
			end
		end

		-- Root folders come first
		if a_is_root and not b_is_root then
			return true
		end
		if b_is_root and not a_is_root then
			return false
		end

		-- Otherwise alphabetical
		return a < b
	end)

	return partials_dirs
end

local function get_repository_path(file_path)
	local git_root = vim.fn.system("git rev-parse --show-toplevel"):gsub("%s+", "")
	return file_path:sub(#git_root + 2) -- +2 to remove leading slash
end

-- Function specifically for code block imports
function M.select_code_block()
	-- Capture the current buffer and window
	local current_bufnr = vim.api.nvim_get_current_buf()
	local current_win = vim.api.nvim_get_current_win()

	-- Get current file path and version context
	local current_file = vim.api.nvim_buf_get_name(current_bufnr)
	local git_root = vim.fn.system("git rev-parse --show-toplevel"):gsub("%s+", "")
	local version_context = get_version_context(current_file, git_root)

	-- Get filtered _partials directories based on version context
	local partials_dirs = get_all_partials_dirs(version_context, git_root)

	if vim.tbl_isempty(partials_dirs) then
		print("No _partials directories found in the repository.")
		return
	end

	-- Build find command to exclude markdown files and focus on code files
	local find_command = {
		"find",
	}

	-- Add all search directories
	for _, dir in ipairs(partials_dirs) do
		table.insert(find_command, dir)
	end

	-- Add conditions to exclude markdown and include code files
	table.insert(find_command, "-type")
	table.insert(find_command, "f")
	table.insert(find_command, "(")

	-- Include common code file extensions
	local code_extensions = {
		"*.yaml",
		"*.yml",
		"*.json",
		"*.js",
		"*.jsx",
		"*.ts",
		"*.tsx",
		"*.sh",
		"*.bash",
		"*.py",
		"*.go",
		"*.rs",
		"*.toml",
		"*.xml",
		"*.conf",
		"*.ini",
		"*.env",
		"*.properties",
		"*.sql",
	}

	for i, ext in ipairs(code_extensions) do
		if i > 1 then
			table.insert(find_command, "-o")
		end
		table.insert(find_command, "-name")
		table.insert(find_command, ext)
	end

	table.insert(find_command, ")")

	-- Exclude markdown files explicitly
	table.insert(find_command, "!")
	table.insert(find_command, "-name")
	table.insert(find_command, "*.md")
	table.insert(find_command, "!")
	table.insert(find_command, "-name")
	table.insert(find_command, "*.mdx")

	-- Use Telescope to browse code files
	require("telescope.builtin").find_files({
		prompt_title = "Select Code File",
		find_command = find_command,
		layout_strategy = "flex",
		layout_config = {
			flex = {
				flip_columns = 120, -- Switch to vertical layout on smaller windows
			},
			horizontal = {
				preview_width = 0.35, -- 35% for preview on the right
				preview_cutoff = 0,
				prompt_position = "top",
				mirror = false, -- This ensures preview is on the right
			},
			width = 0.95,
			height = 0.85,
		},
		sorting_strategy = "ascending",
		path_display = function(opts, path)
			-- Get the tail (filename) and calculate how much of the path we can show
			local tail = require("telescope.utils").path_tail(path)
			local local_git_root = vim.fn.system("git rev-parse --show-toplevel"):gsub("%s+", "")

			-- Remove git root from path to make it relative
			local relative_path = path
			if local_git_root and local_git_root ~= "" then
				relative_path = path:sub(#local_git_root + 2) -- +2 to remove the leading slash
			end

			-- Return a formatted display with more visible path
			return string.format("%s  [%s]", tail, relative_path)
		end,
		attach_mappings = function(prompt_bufnr, map)
			map("i", "<CR>", function()
				local selection = require("telescope.actions.state").get_selected_entry()
				local partial_path = selection.path

				-- Close Telescope before prompting
				require("telescope.actions").close(prompt_bufnr)

				-- Generate default component name based on the file name
				local partial_name = M.to_camel_case(partial_path)

				-- Prompt for the component name with default value
				partial_name = vim.fn.input("Name the code block: ", partial_name)

				-- Switch back to the original window and buffer
				vim.api.nvim_set_current_win(current_win)
				vim.api.nvim_set_current_buf(current_bufnr)

				-- Insert code block with raw loader
				M.insert_partial_in_buffer(current_bufnr, partial_name, partial_path, true)
			end)
			return true
		end,
	})
end

-- Function to convert a string to CamelCase using only the file name
function M.to_camel_case(str)
	-- Extract the file name without extension
	local file_name = vim.fn.fnamemodify(str, ":t:r")

	local words = {}
	-- Split the file name by hyphens and underscores
	for word in string.gmatch(file_name, "[^%-%_]+") do
		word = word:gsub("^%l", string.upper)
		table.insert(words, word)
	end
	return table.concat(words)
end

-- Function to convert file name to readable text
function M.to_readable_text(str)
	-- Extract the file name without extension
	local file_name = vim.fn.fnamemodify(str, ":t:r")
	-- Replace hyphens and underscores with spaces
	return file_name:gsub("[%-_]", " ")
end

-- Function to convert string to camelCase (first letter lowercase, for function names)
local function to_camel_case_lower(str)
	local pascal = M.to_camel_case(str)
	-- Convert first letter to lowercase
	return pascal:sub(1, 1):lower() .. pascal:sub(2)
end

-- Function to get relative path between two absolute paths
local function get_relative_path(from_dir, to_path)
	local git_root = vim.fn.system("git rev-parse --show-toplevel"):gsub("%s+", "")

	local from_rel = from_dir:sub(#git_root + 2)
	local to_rel = to_path:sub(#git_root + 2)

	local from_parts = vim.split(from_rel, "/")
	local to_parts = vim.split(to_rel, "/")

	local i = 1
	while i <= #from_parts and i <= #to_parts and from_parts[i] == to_parts[i] do
		i = i + 1
	end

	local result = {}
	for _ = i, #from_parts do
		table.insert(result, "..")
	end

	for j = i, #to_parts do
		table.insert(result, to_parts[j])
	end

	return table.concat(result, "/")
end

-- Function to get language identifier from file extension
local function get_language_from_extension(file_path)
	local ext = vim.fn.fnamemodify(file_path, ":e"):lower()

	-- Common mappings where the extension doesn't match the language identifier
	local special_mappings = {
		yml = "yaml",
		js = "javascript",
		ts = "typescript",
		sh = "bash",
		py = "python",
		rs = "rust",
		md = "markdown",
	}

	-- Return the special mapping if it exists, otherwise use the extension itself
	return special_mappings[ext] or ext
end

function M.insert_partial_in_buffer(bufnr, partial_name, partial_path, is_raw_loader)
	-- Switch to the buffer
	vim.api.nvim_set_current_buf(bufnr)

	-- Check if import already exists
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local import_exists = false
	for _, line in ipairs(lines) do
		if line:match("^import") then
			local import_name = line:match("^import%s+(%S+)%s+from")
			if import_name == partial_name then
				import_exists = true
				break
			end
		end
	end

	-- Get the cursor position in the correct window
	local cursor_position = vim.api.nvim_win_get_cursor(0)
	local current_line = cursor_position[1]

	local insert_text
	if is_raw_loader then
		-- For raw loader, create CodeBlock component with detected language
		local language = get_language_from_extension(partial_path)
		insert_text = string.format(
			'<CodeBlock language="%s" title="%s">{%s}</CodeBlock>',
			language,
			M.to_readable_text(partial_path),
			partial_name
		)
	else
		-- For regular partials
		insert_text = string.format("<%s />", partial_name)
	end

	-- Insert the component at the cursor position
	vim.api.nvim_buf_set_lines(bufnr, current_line - 1, current_line - 1, false, { insert_text })

	-- Position cursor on the inserted component tag
	local line_content = vim.api.nvim_buf_get_lines(bufnr, current_line - 1, current_line, false)[1]
	-- Find the position of '<' in the inserted line
	local tag_start = line_content:find("<")
	if tag_start then
		vim.api.nvim_win_set_cursor(0, { current_line, tag_start - 1 })
	end

	-- If import already exists, skip adding it
	if import_exists then
		return
	end

	-- Rest of the function (imports handling) remains the same
	local current_file_path = vim.api.nvim_buf_get_name(bufnr)
	local current_file_dir = vim.fn.fnamemodify(current_file_path, ":h")

	local import_statement
	if is_raw_loader then
		-- Get repository path for checking
		local repo_path = get_repository_path(partial_path)

		-- Check if this path is explicitly allowed to use @site
		local use_site_import = false
		for _, allowed_pattern in ipairs(config.allowed_site_paths or {}) do
			if repo_path:match(allowed_pattern) then
				use_site_import = true
				break
			end
		end

		if use_site_import then
			-- Use @site for shared non-versioned content only
			import_statement = string.format("import %s from '!!raw-loader!@site/%s';", partial_name, repo_path)
		else
			-- Use relative path for everything else
			local relative_path = get_relative_path(current_file_dir, partial_path)
			import_statement = string.format("import %s from '!!raw-loader!%s';", partial_name, relative_path)
		end
	else
		-- Get repository path for checking
		local repo_path = get_repository_path(partial_path)

		-- Check if this path is explicitly allowed to use @site
		local use_site_import = false
		for _, allowed_pattern in ipairs(config.allowed_site_paths or {}) do
			if repo_path:match(allowed_pattern) then
				use_site_import = true
				break
			end
		end

		if use_site_import then
			-- Use @site for shared non-versioned content only
			import_statement = string.format("import %s from '@site/%s';", partial_name, repo_path)
		else
			-- Use relative path for everything else
			local relative_path = get_relative_path(current_file_dir, partial_path)
			import_statement = string.format("import %s from '%s';", partial_name, relative_path)
		end
	end

	-- Get the buffer lines again (for import insertion)
	lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local insert_pos = 1
	local found_front_matter_start = false
	local found_front_matter_end = false
	local has_codeblock_import = false

	-- Find the front matter and import section from the top
	for i, line in ipairs(lines) do
		if not found_front_matter_start then
			if line:match("^---$") then
				found_front_matter_start = true
			end
		elseif not found_front_matter_end then
			if line:match("^---$") then
				found_front_matter_end = true
				insert_pos = i + 1
			end
		elseif line:match("^import") then
			insert_pos = i + 1
			if line:match("^import CodeBlock from '@theme/CodeBlock'") then
				has_codeblock_import = true
			end
		end
	end

	-- Insert imports
	local imports = {}
	if is_raw_loader and not has_codeblock_import then
		table.insert(imports, "import CodeBlock from '@theme/CodeBlock'")
	end
	table.insert(imports, import_statement)

	if #imports > 0 then
		table.insert(imports, "") -- Add empty line after imports
		vim.api.nvim_buf_set_lines(bufnr, insert_pos - 1, insert_pos - 1, false, imports)
	end
end

-- Function to insert URL reference at cursor
local function insert_url_reference(bufnr, target_path)
	-- Get current file directory
	local current_file_path = vim.api.nvim_buf_get_name(bufnr)
	local current_file_dir = vim.fn.fnamemodify(current_file_path, ":h")

	-- Get relative path from current file to target, without extension
	local url_path = get_relative_path(current_file_dir, target_path)
	-- Remove file extension for clean URLs
	url_path = vim.fn.fnamemodify(url_path, ":r")

	-- Get the cursor position
	local cursor_position = vim.api.nvim_win_get_cursor(0)
	local current_line = cursor_position[1]

	-- Generate default link text from file name
	local default_text = M.to_readable_text(target_path)

	-- Prompt for link text with default value
	local link_text = vim.fn.input("Enter link text: ", default_text)
	if link_text == "" then
		link_text = default_text
	end

	local markdown_link = string.format("[%s](%s)", link_text, url_path)

	-- Insert the markdown link at cursor position
	local line_content = vim.api.nvim_buf_get_lines(bufnr, current_line - 1, current_line, false)[1]
	local cursor_col = cursor_position[2]

	-- Split the line at cursor position and insert the link
	local new_line = string.sub(line_content, 1, cursor_col)
		.. markdown_link
		.. string.sub(line_content, cursor_col + 1)
	vim.api.nvim_buf_set_lines(bufnr, current_line - 1, current_line, false, { new_line })
end

function M.select_partial()
	-- Capture the current buffer and window
	local current_bufnr = vim.api.nvim_get_current_buf()
	local current_win = vim.api.nvim_get_current_win()

	-- Get current file path and version context
	local current_file = vim.api.nvim_buf_get_name(current_bufnr)
	local git_root = vim.fn.system("git rev-parse --show-toplevel"):gsub("%s+", "")
	local version_context = get_version_context(current_file, git_root)

	-- Get filtered _partials directories based on version context
	local partials_dirs = get_all_partials_dirs(version_context, git_root)

	if vim.tbl_isempty(partials_dirs) then
		print("No _partials directories found in the repository.")
		return
	end

	-- Collect all partial files and sort them
	local all_files = {}
	for _, dir in ipairs(partials_dirs) do
		local function scan_files(directory)
			local entries = vim.fn.readdir(directory)
			for _, name in ipairs(entries) do
				local full_path = directory .. "/" .. name
				if vim.fn.isdirectory(full_path) == 1 then
					scan_files(full_path)
				elseif name:match("%.mdx?$") then
					-- Check if file is from root docs folder
					local relative_path = full_path:sub(#git_root + 2)
					local is_root = false
					for _, pattern in ipairs(config.allowed_site_paths) do
						if relative_path:match(pattern) then
							is_root = true
							break
						end
					end
					table.insert(all_files, {
						path = full_path,
						is_root = is_root,
						relative_path = relative_path,
					})
				end
			end
		end
		scan_files(dir)
	end

	-- Sort: root docs files first, then alphabetically
	table.sort(all_files, function(a, b)
		if a.is_root and not b.is_root then
			return true
		end
		if b.is_root and not a.is_root then
			return false
		end
		return a.path < b.path
	end)

	-- Use Telescope with custom picker
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Select Partial",
			finder = finders.new_table({
				results = all_files,
				entry_maker = function(entry)
					local tail = require("telescope.utils").path_tail(entry.path)
					local display = string.format("%s  [%s]", tail, entry.relative_path)
					return {
						value = entry.path,
						display = display,
						ordinal = entry.path,
						path = entry.path,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = conf.file_previewer({}),
			layout_strategy = "flex",
			layout_config = {
				flex = {
					flip_columns = 120,
				},
				horizontal = {
					preview_width = 0.35,
					preview_cutoff = 0,
					prompt_position = "top",
					mirror = false,
				},
				width = 0.95,
				height = 0.85,
			},
			sorting_strategy = "ascending",
			attach_mappings = function(prompt_bufnr, map)
				map("i", "<CR>", function()
					local selection = action_state.get_selected_entry()
					local partial_path = selection.path

					-- Generate default component name based on the file name
					local partial_name = M.to_camel_case(partial_path)

					-- Prompt for the component name with default value
					partial_name = vim.fn.input("Name the partial: ", partial_name)

					-- Close Telescope before switching back
					actions.close(prompt_bufnr)

					-- Switch back to the original window and buffer
					vim.api.nvim_set_current_win(current_win)
					vim.api.nvim_set_current_buf(current_bufnr)

					-- Insert partial (always as regular import)
					M.insert_partial_in_buffer(current_bufnr, partial_name, partial_path, false)
				end)
				return true
			end,
		})
		:find()
end

function M.insert_url_reference()
	local current_bufnr = vim.api.nvim_get_current_buf()
	local current_win = vim.api.nvim_get_current_win()

	local git_root = vim.fn.system("git rev-parse --show-toplevel"):gsub("%s+", "")
	if git_root == "" then
		print("Not inside a git repository.")
		return
	end

	-- Get current file path and version context
	local current_file = vim.api.nvim_buf_get_name(current_bufnr)
	local version_context = get_version_context(current_file, git_root)

	-- Build search paths based on version context
	local search_paths = {}
	if version_context.type == "versioned" and version_context.folder then
		-- Add version-specific folder only
		-- URLs should only reference docs from the same version
		table.insert(search_paths, git_root .. "/" .. version_context.folder)
	elseif version_context.type == "main" and version_context.project then
		-- Add main project folder only
		-- URLs should only reference docs from the same project
		table.insert(search_paths, git_root .. "/" .. version_context.project)
	else
		-- No version/project context, search entire git root
		search_paths = { git_root }
	end

	-- Use Lua to collect matching files from search paths
	local function collect_md_files()
		local files = {}
		for _, search_path in ipairs(search_paths) do
			local function scan_dir(dir)
				local entries = vim.fn.readdir(dir)
				for _, name in ipairs(entries) do
					local full_path = dir .. "/" .. name
					if vim.fn.isdirectory(full_path) == 1 then
						-- Skip underscore directories
						if not name:match("^_") and name ~= ".git" and name ~= "node_modules" then
							scan_dir(full_path)
						end
					elseif name:match("%.mdx?$") then
						table.insert(files, full_path)
					end
				end
			end
			if vim.fn.isdirectory(search_path) == 1 then
				scan_dir(search_path)
			end
		end
		return files
	end

	local md_files = collect_md_files()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Select MD(X) File to Reference",
			finder = finders.new_table({
				results = md_files,
				entry_maker = function(entry)
					local display_path = entry
					if git_root and entry:sub(1, #git_root) == git_root then
						display_path = entry:sub(#git_root + 2)
					end
					return {
						value = entry,
						display = display_path,
						ordinal = display_path,
						path = entry,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = conf.file_previewer({}),
			layout_strategy = "flex",
			layout_config = {
				flex = {
					flip_columns = 120, -- Switch to vertical layout on smaller windows
				},
				horizontal = {
					preview_width = 0.35, -- 35% for preview on the right
					preview_cutoff = 0,
					prompt_position = "top",
					mirror = false, -- This ensures preview is on the right
				},
				width = 0.95,
				height = 0.85,
			},
			sorting_strategy = "ascending",
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					local file_path = selection.path
					actions.close(prompt_bufnr)
					vim.api.nvim_set_current_win(current_win)
					vim.api.nvim_set_current_buf(current_bufnr)
					insert_url_reference(current_bufnr, file_path)
				end)
				return true
			end,
		})
		:find()
end

-- Function to insert component in buffer
local function insert_component_in_buffer(bufnr, component_name)
	-- Switch to the buffer
	vim.api.nvim_set_current_buf(bufnr)

	-- Get the cursor position in the correct window
	local cursor_position = vim.api.nvim_win_get_cursor(0)
	local current_line = cursor_position[1]

	local component_insert = string.format("<%s />", component_name)

	-- Insert the component at the cursor position
	vim.api.nvim_buf_set_lines(bufnr, current_line - 1, current_line - 1, false, { component_insert })

	-- Add import statement
	local import_statement = string.format("import %s from '@site/src/components/%s';", component_name, component_name)

	-- Get the buffer lines
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local insert_pos = 1
	local found_front_matter_start = false
	local found_front_matter_end = false

	-- Find the front matter and import section from the top
	for i, line in ipairs(lines) do
		if not found_front_matter_start then
			if line:match("^---$") then
				found_front_matter_start = true
			end
		elseif not found_front_matter_end then
			if line:match("^---$") then
				found_front_matter_end = true
				insert_pos = i + 1
			end
		elseif line:match("^import") then
			insert_pos = i + 1
		end
	end

	-- Insert the import statement
	vim.api.nvim_buf_set_lines(bufnr, insert_pos - 1, insert_pos - 1, false, { "", import_statement, "" })
end

function M.select_component()
	-- Capture the current buffer and window
	local current_bufnr = vim.api.nvim_get_current_buf()
	local current_win = vim.api.nvim_get_current_win()

	-- Get components directory path from config or use default
	local components_dir = config.components_dir

	if not components_dir then
		-- Try to find default components directory relative to git root
		local git_root = vim.fn.system("git rev-parse --show-toplevel"):gsub("%s+", "")
		if git_root ~= "" then
			components_dir = git_root .. "/src/components"
		else
			-- Fallback to current directory
			components_dir = vim.fn.getcwd() .. "/src/components"
		end
	end

	-- Expand ~ if present
	components_dir = vim.fn.expand(components_dir)

	if vim.fn.isdirectory(components_dir) ~= 1 then
		print("Components directory not found at: " .. components_dir)
		return
	end

	-- Get list of component directories
	local components = vim.fn.readdir(components_dir)
	local component_entries = {}

	-- Create entries for telescope
	for _, name in ipairs(components) do
		local full_path = components_dir .. "/" .. name
		if vim.fn.isdirectory(full_path) == 1 then
			table.insert(component_entries, {
				value = name,
				display = name,
				ordinal = name:lower(),
			})
		end
	end

	-- Create picker using Telescope
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	-- Function to get component file content
	local function get_component_content(name)
		local base_path = components_dir .. "/" .. name
		local possible_files = {
			"/index.js",
			"/index.jsx",
			"/" .. name .. ".js",
			"/" .. name .. ".jsx",
		}

		for _, file in ipairs(possible_files) do
			local full_path = base_path .. file
			if vim.fn.filereadable(full_path) == 1 then
				local content = vim.fn.readfile(full_path)
				return table.concat(content, "\n")
			end
		end
		return "No component file found"
	end

	pickers
		.new({}, {
			prompt_title = "Select Component",
			finder = finders.new_table({
				results = component_entries,
				entry_maker = function(entry)
					return {
						value = entry.value,
						display = entry.display,
						ordinal = entry.ordinal,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = require("telescope.previewers").new_buffer_previewer({
				title = "Component Content",
				define_preview = function(self, entry)
					local content = get_component_content(entry.value)
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(content, "\n"))

					-- Set filetype for syntax highlighting
					if content:match("%.jsx?$") then
						vim.bo[self.state.bufnr].filetype = "javascriptreact"
					else
						vim.bo[self.state.bufnr].filetype = "javascript"
					end
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)

					-- Switch back to the original window and buffer
					vim.api.nvim_set_current_win(current_win)
					vim.api.nvim_set_current_buf(current_bufnr)

					-- Insert component
					insert_component_in_buffer(current_bufnr, selection.value)
				end)
				return true
			end,
		})
		:find()
end

-- Export configuration getter for debugging
function M.get_config()
	return config
end

-- ========================================
-- Plugin Scaffolder Functions
-- ========================================

-- Generate plugin template based on type
function M.generate_plugin_template(opts)
	local name = opts.name or "my-plugin"
	local plugin_type = opts.type or "lifecycle"

	local camel_name = to_camel_case_lower(name)

	if plugin_type == "lifecycle" then
		return string.format(
			[[module.exports = function %s(context, options) {
  return {
    name: '%s',

    async loadContent() {
      // Load data from source
    },

    async contentLoaded({content, actions}) {
      // Create routes and process content
    },

    async postBuild({siteConfig, routesPaths, outDir, head}) {
      // Execute after the production build
    },

    async postStart({siteConfig}) {
      // Execute after the dev server starts
    },
  };
};
]],
			camel_name,
			name
		)
	elseif plugin_type == "content" then
		return string.format(
			[[module.exports = function %s(context, options) {
  return {
    name: '%s',

    async loadContent() {
      // Load content from files/API
      return {
        /* your content data */
      };
    },

    async contentLoaded({content, actions}) {
      const {createData, addRoute} = actions;

      // Create pages/routes
      const data = await createData('data.json', JSON.stringify(content));

      addRoute({
        path: '/%s',
        component: '@site/src/components/%sPage.js',
        modules: {
          data,
        },
        exact: true,
      });
    },
  };
};
]],
			camel_name,
			name,
			name,
			camel_name
		)
	elseif plugin_type == "theme" then
		return string.format(
			[[module.exports = function %s(context, options) {
  return {
    name: '%s',

    getThemePath() {
      return './theme';
    },

    getTypeScriptThemePath() {
      return './src/theme';
    },

    getClientModules() {
      return ['./customCss.css'];
    },
  };
};
]],
			camel_name,
			name
		)
	end

	return ""
end

-- Scaffold a new plugin with directory structure
function M.scaffold_plugin(opts)
	local name = opts.name or "my-plugin"
	local plugin_type = opts.type or "lifecycle"
	local write_file = opts.write_file -- For testing

	local git_root = vim.fn.system("git rev-parse --show-toplevel"):gsub("%s+", "")
	if git_root == "" then
		git_root = vim.fn.getcwd()
	end

	local plugin_dir = git_root .. "/plugins/" .. name

	-- Create directory
	vim.fn.mkdir(plugin_dir, "p")

	-- Generate template
	local template = M.generate_plugin_template({ name = name, type = plugin_type })

	-- Write index.js
	local index_path = plugin_dir .. "/index.js"
	if write_file then
		write_file(index_path, template)
	else
		local file = io.open(index_path, "w")
		if file then
			file:write(template)
			file:close()
		end
	end

	-- Create package.json
	local package_json = string.format(
		[[{
  "name": "%s",
  "version": "0.0.1",
  "description": "A Docusaurus plugin",
  "main": "index.js",
  "dependencies": {}
}
]],
		name
	)

	local package_path = plugin_dir .. "/package.json"
	if write_file then
		write_file(package_path, package_json)
	else
		local file = io.open(package_path, "w")
		if file then
			file:write(package_json)
			file:close()
		end
	end

	print(string.format("Plugin scaffolded at: %s", plugin_dir))
	return plugin_dir
end

-- Interactive plugin scaffolder command
function M.create_plugin()
	local name = vim.fn.input("Plugin name: ", "my-plugin")
	if name == "" then
		return
	end

	local type_choice = vim.fn.confirm("Select plugin type:", "&Lifecycle\n&Content\n&Theme", 1)

	local plugin_types = { "lifecycle", "content", "theme" }
	local plugin_type = plugin_types[type_choice] or "lifecycle"

	M.scaffold_plugin({ name = name, type = plugin_type })
end

-- ========================================
-- API Browser Functions
-- ========================================

-- Get Docusaurus version from package.json
function M.get_docusaurus_version()
	local git_root = vim.fn.system("git rev-parse --show-toplevel"):gsub("%s+", "")
	if git_root == "" then
		git_root = vim.fn.getcwd()
	end

	local package_path = git_root .. "/package.json"
	if vim.fn.filereadable(package_path) ~= 1 then
		return nil
	end

	local lines = vim.fn.readfile(package_path)
	local content = table.concat(lines, "\n")

	-- Try to find @docusaurus/core version
	local version = content:match('"@docusaurus/core"%s*:%s*"[%^~]?([%d%.]+)"')

	return version
end

-- Get configuration options for a Docusaurus version
-- Fetch and parse Docusaurus config options from GitHub
function M.get_config_options(version, mock_content)
	local content = mock_content

	-- Fetch from GitHub if no mock content provided
	if not content then
		local url =
			"https://raw.githubusercontent.com/facebook/docusaurus/main/website/docs/api/docusaurus.config.js.mdx"

		-- Try curl first (Linux/Mac/WSL), then wget (fallback), then PowerShell (Windows)
		local fetch_commands = {
			string.format("curl -sL '%s'", url),
			string.format("wget -qO- '%s'", url),
			string.format(
				"powershell -Command \"Invoke-WebRequest -Uri '%s' -UseBasicParsing | Select-Object -ExpandProperty Content\"",
				url
			),
		}

		for _, cmd in ipairs(fetch_commands) do
			content = vim.fn.system(cmd)
			if vim.v.shell_error == 0 and content ~= "" then
				break
			end
		end

		if vim.v.shell_error ~= 0 or content == "" then
			print("Failed to fetch Docusaurus config documentation from GitHub")
			print("Please ensure curl, wget, or PowerShell is available")
			return {}
		end
	end

	local options = {}

	-- Parse markdown structure: ### `optionName` {#anchor}
	-- Followed by: - Type: `type`
	-- Then description and examples
	local current_option = nil
	local in_description = false
	local in_example = false
	local example_lines = {}

	for line in content:gmatch("[^\r\n]+") do
		-- Match config option heading: ### `optionName` {#anchor}
		local option_name, anchor = line:match("^###%s+`([^`]+)`%s+{#([^}]+)}")
		if option_name and anchor then
			-- Save previous option if exists
			if current_option then
				current_option.example = table.concat(example_lines, "\n")
				table.insert(options, current_option)
			end

			-- Start new option
			current_option = {
				name = option_name,
				anchor = anchor,
				type = "unknown",
				description = "",
				example = "",
				url = "https://docusaurus.io/docs/api/docusaurus-config#" .. anchor,
			}
			in_description = false
			in_example = false
			example_lines = {}
		elseif current_option then
			-- Match type: - Type: `type`
			local type_str = line:match("^%-%s+Type:%s+`([^`]+)`")
			if type_str then
				current_option.type = type_str
				in_description = true
			-- Match code block start for examples
			elseif line:match("^```") then
				if in_example then
					in_example = false
				else
					in_example = true
				end
			-- Collect example lines
			elseif in_example then
				table.insert(example_lines, line)
			-- Collect description lines (first paragraph after type)
			elseif in_description and line ~= "" and not line:match("^```") and not line:match("^%-%s+Type:") then
				if current_option.description == "" then
					current_option.description = line
				end
			end
		end
	end

	-- Save last option
	if current_option then
		current_option.example = table.concat(example_lines, "\n")
		table.insert(options, current_option)
	end

	return options
end

-- Browse Docusaurus API options using Telescope
function M.browse_api()
	local version = M.get_docusaurus_version()
	if not version then
		print("Could not detect Docusaurus version from package.json")
		version = "3.0.0" -- Default
	end

	local options = M.get_config_options(version)

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	pickers
		.new({}, {
			prompt_title = string.format("Docusaurus Config Options (v%s)", version),
			finder = finders.new_table({
				results = options,
				entry_maker = function(entry)
					return {
						value = entry,
						display = string.format("%s (%s)", entry.name, entry.type),
						ordinal = entry.name:lower(),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Option Details",
				define_preview = function(self, entry)
					local option = entry.value

					-- Split example into lines if it contains newlines
					local example_lines = {}
					if option.example and option.example ~= "" then
						for line in option.example:gmatch("[^\r\n]+") do
							table.insert(example_lines, line)
						end
					end

					local lines = {
						"Name: " .. option.name,
						"Type: " .. option.type,
						"",
						"Description:",
						option.description,
						"",
						"Documentation:",
						option.url or "N/A",
						"",
						"Example:",
					}

					-- Append example lines
					for _, line in ipairs(example_lines) do
						table.insert(lines, line)
					end

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "javascript"
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					local option = selection.value
					actions.close(prompt_bufnr)

					-- Open browser to the config option's documentation
					if option.url then
						local open_cmd
						if vim.fn.has("mac") == 1 then
							open_cmd = "open"
						elseif vim.fn.has("unix") == 1 then
							open_cmd = "xdg-open"
						elseif vim.fn.has("win32") == 1 then
							open_cmd = "start"
						end

						if open_cmd then
							vim.fn.system(string.format("%s '%s'", open_cmd, option.url))
							print(string.format("Opening documentation: %s", option.url))
						end
					end
				end)
				return true
			end,
		})
		:find()
end

-- ========================================
-- External Repos Management Functions
-- ========================================

-- Import a new external Docusaurus repository
function M.import_repo()
	-- Prompt for git URL
	local git_url = vim.fn.input("Git repository URL: ")
	if git_url == "" then
		print("Cancelled: No URL provided")
		return
	end

	-- Prompt for repo name with default derived from URL
	local default_name = derive_repo_name(git_url)
	local repo_name = vim.fn.input("Repository name: ", default_name)
	if repo_name == "" then
		repo_name = default_name
	end

	-- Prompt for docusaurus root path
	local docusaurus_root = vim.fn.input("Path to Docusaurus root (relative): ", ".")
	if docusaurus_root == "" then
		docusaurus_root = "."
	end

	-- Check if repo already exists
	local existing = find_repo_by_name(repo_name)
	local repo_path = get_repo_path(repo_name)

	if existing then
		print(string.format("Repository '%s' already exists. Using existing clone.", repo_name))
	else
		-- Ensure base directory exists
		local base_dir = get_xdg_data_dir()
		if vim.fn.isdirectory(base_dir) ~= 1 then
			vim.fn.mkdir(base_dir, "p")
		end

		-- Clone the repository
		print(string.format("Cloning %s...", git_url))
		local clone_cmd = string.format("git clone '%s' '%s' 2>&1", git_url, repo_path)
		local output = vim.fn.system(clone_cmd)

		if vim.v.shell_error ~= 0 then
			print("Failed to clone repository: " .. output)
			return
		end

		-- Add to registry
		local registry = load_repos_registry()
		table.insert(registry.repos, {
			name = repo_name,
			git_url = git_url,
			docusaurus_root = docusaurus_root,
			cloned_at = os.date("%Y-%m-%dT%H:%M:%S"),
		})

		if not save_repos_registry(registry) then
			print("Warning: Failed to save registry")
		end

		print(string.format("Repository cloned to: %s", repo_path))
	end

	-- Ensure docs-updates branch
	local success, message = ensure_docs_branch(repo_path)
	print(message)

	-- Set as active repo
	state.active_repo = {
		name = repo_name,
		path = repo_path,
		docusaurus_root = docusaurus_root,
	}

	print(string.format("Active repo set to: %s", repo_name))
end

-- Select an external repo using Telescope picker
function M.select_repo()
	local registry = load_repos_registry()

	if vim.tbl_isempty(registry.repos) then
		print("No external repos found. Use :DocusaurusImportRepo to add one.")
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	pickers
		.new({}, {
			prompt_title = "Select Docusaurus Repository",
			finder = finders.new_table({
				results = registry.repos,
				entry_maker = function(entry)
					local display = string.format("%s [%s]", entry.name, entry.git_url)
					return {
						value = entry,
						display = display,
						ordinal = entry.name:lower(),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Repository Info",
				define_preview = function(self, entry)
					local repo = entry.value
					local repo_path = get_repo_path(repo.name)
					local current_branch = get_current_branch(repo_path)

					local lines = {
						"Name: " .. repo.name,
						"Git URL: " .. repo.git_url,
						"Docusaurus Root: " .. repo.docusaurus_root,
						"Cloned At: " .. (repo.cloned_at or "Unknown"),
						"",
						"Local Path: " .. repo_path,
						"Current Branch: " .. current_branch,
					}

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					local repo = selection.value
					actions.close(prompt_bufnr)

					local repo_path = get_repo_path(repo.name)

					-- Ensure docs-updates branch
					local success, message = ensure_docs_branch(repo_path)
					print(message)

					-- Set as active repo
					state.active_repo = {
						name = repo.name,
						path = repo_path,
						docusaurus_root = repo.docusaurus_root,
					}

					print(string.format("Active repo set to: %s", repo.name))
				end)
				return true
			end,
		})
		:find()
end

-- Remove an external repo from registry
function M.remove_repo()
	local registry = load_repos_registry()

	if vim.tbl_isempty(registry.repos) then
		print("No external repos found.")
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Select Repository to Remove",
			finder = finders.new_table({
				results = registry.repos,
				entry_maker = function(entry)
					local display = string.format("%s [%s]", entry.name, entry.git_url)
					return {
						value = entry,
						display = display,
						ordinal = entry.name:lower(),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					local repo = selection.value
					actions.close(prompt_bufnr)

					-- Confirm deletion
					local choice = vim.fn.confirm(
						string.format("Remove '%s'?", repo.name),
						"&Remove from registry only\n&Delete files too\n&Cancel",
						3
					)

					if choice == 3 or choice == 0 then
						print("Cancelled")
						return
					end

					-- Remove from registry
					local new_repos = {}
					for _, r in ipairs(registry.repos) do
						if r.name ~= repo.name then
							table.insert(new_repos, r)
						end
					end
					registry.repos = new_repos
					save_repos_registry(registry)

					-- Delete files if requested
					if choice == 2 then
						local repo_path = get_repo_path(repo.name)
						vim.fn.delete(repo_path, "rf")
						print(string.format("Removed '%s' and deleted files", repo.name))
					else
						print(string.format("Removed '%s' from registry (files kept)", repo.name))
					end

					-- Clear active repo if it was the removed one
					if state.active_repo and state.active_repo.name == repo.name then
						state.active_repo = nil
					end
				end)
				return true
			end,
		})
		:find()
end

-- Update an external repo's configuration
function M.update_repo()
	local registry = load_repos_registry()

	if vim.tbl_isempty(registry.repos) then
		print("No external repos found. Use :DocusaurusImportRepo to add one.")
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Select Repository to Update",
			finder = finders.new_table({
				results = registry.repos,
				entry_maker = function(entry)
					local display = string.format("%s [%s]", entry.name, entry.git_url)
					return {
						value = entry,
						display = display,
						ordinal = entry.name:lower(),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					local repo = selection.value
					local old_name = repo.name
					actions.close(prompt_bufnr)

					-- Prompt for new values with current as default
					print(string.format("Updating '%s' - press Enter to keep current value", old_name))

					local new_name = vim.fn.input("Name: ", repo.name)
					if new_name == "" then
						new_name = repo.name
					end

					local new_git_url = vim.fn.input("Git URL: ", repo.git_url)
					if new_git_url == "" then
						new_git_url = repo.git_url
					end

					local new_docusaurus_root = vim.fn.input("Docusaurus root: ", repo.docusaurus_root)
					if new_docusaurus_root == "" then
						new_docusaurus_root = repo.docusaurus_root
					end

					-- Check if anything changed
					if new_name == repo.name and new_git_url == repo.git_url and new_docusaurus_root == repo.docusaurus_root then
						print("No changes made")
						return
					end

					-- Check for name collision if name changed
					if new_name ~= old_name then
						for _, r in ipairs(registry.repos) do
							if r.name == new_name then
								print(string.format("Error: A repo named '%s' already exists", new_name))
								return
							end
						end

						-- Rename the cloned directory
						local old_path = get_repo_path(old_name)
						local new_path = get_repo_path(new_name)

						if vim.fn.isdirectory(old_path) == 1 then
							local mv_cmd = string.format("mv '%s' '%s' 2>&1", old_path, new_path)
							local output = vim.fn.system(mv_cmd)
							if vim.v.shell_error ~= 0 then
								print("Failed to rename directory: " .. output)
								return
							end
						end
					end

					-- Update registry entry
					for i, r in ipairs(registry.repos) do
						if r.name == old_name then
							registry.repos[i].name = new_name
							registry.repos[i].git_url = new_git_url
							registry.repos[i].docusaurus_root = new_docusaurus_root
							break
						end
					end

					if save_repos_registry(registry) then
						print(string.format("Updated repo '%s'", new_name))
					else
						print("Warning: Failed to save registry")
					end

					-- Update active repo if it was the one we modified
					if state.active_repo and state.active_repo.name == old_name then
						state.active_repo.name = new_name
						state.active_repo.path = get_repo_path(new_name)
						state.active_repo.docusaurus_root = new_docusaurus_root
					end
				end)
				return true
			end,
		})
		:find()
end

-- Commit changes and push to remote
function M.commit_and_push()
	if not state.active_repo then
		print("No active repo. Use :DocusaurusSelectRepo first.")
		return
	end

	local repo_path = state.active_repo.path
	local branch_name = config.docs_branch_name

	-- Check current branch
	local current_branch = get_current_branch(repo_path)
	if current_branch ~= branch_name then
		print(string.format("Not on %s branch. Current: %s", branch_name, current_branch))
		return
	end

	-- Check for changes
	local status_cmd = string.format("cd '%s' && git status --porcelain", repo_path)
	local status = vim.fn.system(status_cmd):gsub("%s+$", "")

	if status == "" then
		print("No changes to commit")
		return
	end

	-- Show status
	print("Changes to commit:")
	print(status)

	-- Prompt for commit message
	local commit_msg = vim.fn.input("Commit message: ")
	if commit_msg == "" then
		print("Cancelled: No commit message")
		return
	end

	-- Stage all changes
	local add_cmd = string.format("cd '%s' && git add -A 2>&1", repo_path)
	vim.fn.system(add_cmd)

	-- Commit
	local commit_cmd = string.format("cd '%s' && git commit -m '%s' 2>&1", repo_path, commit_msg:gsub("'", "'\\''"))
	local commit_output = vim.fn.system(commit_cmd)

	if vim.v.shell_error ~= 0 then
		print("Failed to commit: " .. commit_output)
		return
	end

	print("Committed successfully")

	-- Push to remote
	local push_cmd = string.format("cd '%s' && git push -u origin %s 2>&1", repo_path, branch_name)
	local push_output = vim.fn.system(push_cmd)

	if vim.v.shell_error ~= 0 then
		print("Failed to push: " .. push_output)
		return
	end

	print(string.format("Pushed to origin/%s", branch_name))
end

-- Sync repo with upstream (pull latest from default branch)
function M.sync_repo()
	if not state.active_repo then
		print("No active repo. Use :DocusaurusSelectRepo first.")
		return
	end

	local repo_path = state.active_repo.path
	local branch_name = config.docs_branch_name
	local default_branch = get_default_branch(repo_path)

	print(string.format("Syncing with %s...", default_branch))

	-- Fetch latest
	local fetch_cmd = string.format("cd '%s' && git fetch origin 2>&1", repo_path)
	local fetch_output = vim.fn.system(fetch_cmd)

	if vim.v.shell_error ~= 0 then
		print("Failed to fetch: " .. fetch_output)
		return
	end

	-- Stash any local changes
	local stash_cmd = string.format("cd '%s' && git stash 2>&1", repo_path)
	vim.fn.system(stash_cmd)

	-- Checkout default branch and pull
	local checkout_default_cmd = string.format("cd '%s' && git checkout %s 2>&1", repo_path, default_branch)
	local checkout_output = vim.fn.system(checkout_default_cmd)

	if vim.v.shell_error ~= 0 then
		print("Failed to checkout " .. default_branch .. ": " .. checkout_output)
		return
	end

	local pull_cmd = string.format("cd '%s' && git pull origin %s 2>&1", repo_path, default_branch)
	local pull_output = vim.fn.system(pull_cmd)

	if vim.v.shell_error ~= 0 then
		print("Failed to pull: " .. pull_output)
		return
	end

	-- Switch back to docs branch
	local checkout_docs_cmd = string.format("cd '%s' && git checkout %s 2>&1", repo_path, branch_name)
	vim.fn.system(checkout_docs_cmd)

	-- Merge default branch into docs branch
	local merge_cmd = string.format("cd '%s' && git merge %s 2>&1", repo_path, default_branch)
	local merge_output = vim.fn.system(merge_cmd)

	if vim.v.shell_error ~= 0 then
		print("Merge conflict or error: " .. merge_output)
		print("Please resolve conflicts manually in: " .. repo_path)
		return
	end

	-- Pop stash if there was one
	local stash_pop_cmd = string.format("cd '%s' && git stash pop 2>&1", repo_path)
	vim.fn.system(stash_pop_cmd)

	print(string.format("Synced %s with %s", branch_name, default_branch))
end

-- ========================================
-- Docusaurus Build Commands
-- ========================================

-- Helper to get the docusaurus working directory
local function get_docusaurus_dir()
	if not state.active_repo then
		return nil, "No active repo. Use :DocusaurusSelectRepo first."
	end

	local repo_path = state.active_repo.path
	local docusaurus_root = state.active_repo.docusaurus_root or "."

	local doc_dir
	if docusaurus_root == "." then
		doc_dir = repo_path
	else
		doc_dir = repo_path .. "/" .. docusaurus_root
	end

	-- Verify docusaurus.config.js exists
	local config_js = doc_dir .. "/docusaurus.config.js"
	local config_ts = doc_dir .. "/docusaurus.config.ts"
	if vim.fn.filereadable(config_js) ~= 1 and vim.fn.filereadable(config_ts) ~= 1 then
		return nil, "No docusaurus.config.js/ts found in: " .. doc_dir
	end

	return doc_dir, nil
end

-- Start the Docusaurus development server
function M.start_dev_server()
	local doc_dir, err = get_docusaurus_dir()
	if not doc_dir then
		print(err)
		return
	end

	print("Starting Docusaurus dev server in: " .. doc_dir)
	print("Press Ctrl+C in the terminal to stop the server")

	-- Open a terminal with npm start
	local cmd = string.format("cd '%s' && npm start", doc_dir)
	vim.cmd("terminal " .. cmd)
end

-- Build the Docusaurus site
function M.build_site()
	local doc_dir, err = get_docusaurus_dir()
	if not doc_dir then
		print(err)
		return
	end

	print("Building Docusaurus site in: " .. doc_dir)

	-- Open a terminal with npm run build
	local cmd = string.format("cd '%s' && npm run build", doc_dir)
	vim.cmd("terminal " .. cmd)
end

-- Serve the built Docusaurus site
function M.serve_site()
	local doc_dir, err = get_docusaurus_dir()
	if not doc_dir then
		print(err)
		return
	end

	-- Check if build directory exists
	local build_dir = doc_dir .. "/build"
	if vim.fn.isdirectory(build_dir) ~= 1 then
		print("No build directory found. Run :DocusaurusBuild first.")
		return
	end

	print("Serving Docusaurus site from: " .. doc_dir)
	print("Press Ctrl+C in the terminal to stop the server")

	-- Open a terminal with npm run serve
	local cmd = string.format("cd '%s' && npm run serve", doc_dir)
	vim.cmd("terminal " .. cmd)
end

-- Clear Docusaurus cache
function M.clear_cache()
	local doc_dir, err = get_docusaurus_dir()
	if not doc_dir then
		print(err)
		return
	end

	print("Clearing Docusaurus cache in: " .. doc_dir)

	-- Run npm run clear (or docusaurus clear)
	local cmd = string.format("cd '%s' && npm run clear 2>&1", doc_dir)
	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		-- Try docusaurus clear directly if npm run clear fails
		cmd = string.format("cd '%s' && npx docusaurus clear 2>&1", doc_dir)
		output = vim.fn.system(cmd)

		if vim.v.shell_error ~= 0 then
			print("Failed to clear cache: " .. output)
			return
		end
	end

	print("Cache cleared successfully")
end

-- Install dependencies for Docusaurus project
function M.install_deps()
	local doc_dir, err = get_docusaurus_dir()
	if not doc_dir then
		print(err)
		return
	end

	print("Installing dependencies in: " .. doc_dir)

	-- Open a terminal with npm install
	local cmd = string.format("cd '%s' && npm install", doc_dir)
	vim.cmd("terminal " .. cmd)
end

-- Get active repo info (for other commands to use)
function M.get_active_repo()
	return state.active_repo
end

-- Print the current doc target path
function M.show_doc_path()
	if not state.active_repo then
		print("No active repo. Use :DocusaurusSelectRepo first.")
		return
	end

	local repo_path = state.active_repo.path
	local docusaurus_root = state.active_repo.docusaurus_root or "."

	-- Build full path to docusaurus content
	local doc_path
	if docusaurus_root == "." then
		doc_path = repo_path
	else
		doc_path = repo_path .. "/" .. docusaurus_root
	end

	print("Active repo: " .. state.active_repo.name)
	print("Doc path: " .. doc_path)
	return doc_path
end

-- Create a symlink in the current working directory to the active repo
function M.create_symlink()
	if not state.active_repo then
		print("No active repo. Use :DocusaurusSelectRepo first.")
		return
	end

	local repo_path = state.active_repo.path
	local docusaurus_root = state.active_repo.docusaurus_root or "."

	-- Build full path to docusaurus content
	local target_path
	if docusaurus_root == "." then
		target_path = repo_path
	else
		target_path = repo_path .. "/" .. docusaurus_root
	end

	-- Prompt for symlink name
	local default_name = state.active_repo.name .. "-docs"
	local link_name = vim.fn.input("Symlink name: ", default_name)
	if link_name == "" then
		print("Cancelled: No symlink name provided")
		return
	end

	local cwd = vim.fn.getcwd()
	local link_path = cwd .. "/" .. link_name

	-- Check if symlink already exists
	if vim.fn.filereadable(link_path) == 1 or vim.fn.isdirectory(link_path) == 1 then
		local overwrite = vim.fn.confirm(
			string.format("'%s' already exists. Overwrite?", link_name),
			"&Yes\n&No",
			2
		)
		if overwrite ~= 1 then
			print("Cancelled")
			return
		end
		vim.fn.delete(link_path, "rf")
	end

	-- Create symlink
	local ln_cmd = string.format("ln -s '%s' '%s' 2>&1", target_path, link_path)
	local output = vim.fn.system(ln_cmd)

	if vim.v.shell_error ~= 0 then
		print("Failed to create symlink: " .. output)
		return
	end

	print(string.format("Created symlink: %s -> %s", link_name, target_path))

	-- Check if we're in a git repo and offer to add to .gitignore
	local git_root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("%s+", "")
	if vim.v.shell_error == 0 and git_root ~= "" then
		local add_to_gitignore = vim.fn.confirm(
			"Add symlink to .gitignore?",
			"&Yes\n&No",
			1
		)

		if add_to_gitignore == 1 then
			local gitignore_path = git_root .. "/.gitignore"

			-- Check if already in .gitignore
			local already_ignored = false
			if vim.fn.filereadable(gitignore_path) == 1 then
				local lines = vim.fn.readfile(gitignore_path)
				for _, line in ipairs(lines) do
					if line == link_name or line == "/" .. link_name then
						already_ignored = true
						break
					end
				end
			end

			if already_ignored then
				print("Already in .gitignore")
			else
				-- Append to .gitignore
				local file = io.open(gitignore_path, "a")
				if file then
					file:write("\n# Docusaurus docs symlink\n")
					file:write(link_name .. "\n")
					file:close()
					print("Added '" .. link_name .. "' to .gitignore")
				else
					print("Warning: Could not write to .gitignore")
				end
			end
		end
	end
end

-- Expose internal functions for testing
M.get_version_context = get_version_context
M.path_matches_context = path_matches_context
M.get_xdg_data_dir = get_xdg_data_dir
M.load_repos_registry = load_repos_registry
M.save_repos_registry = save_repos_registry
M.parse_yaml = parse_yaml
M.serialize_yaml = serialize_yaml

return M
