module sync_subtree;
import std.algorithm : all;
import std.ascii : isHexDigit;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, isDir, isSymlink, mkdir, mkdirRecurse, rename, rmdirRecurse;
import std.format : format;
import std.path : buildPath, dirName, dirSeparator, isAbsolute;
import std.process : Config, execute;
import std.stdio : stderr, stdout, writeln;
import std.string : endsWith, indexOf, lastIndexOf, replace, split, splitLines, startsWith, strip;
import std.uuid : randomUUID;

private enum SourceKind {
	defaultBranch,
	branch,
	commit,
}

private struct Options {
	string repository;
	string subtree;
	SourceKind sourceKind;
	string source;
}

private enum USAGE =
	"Usage:\n" ~
	"  sync-subtree <repository> <subtree>\n" ~
	"  sync-subtree <repository> <subtree> --branch <name>\n" ~
	"  sync-subtree <repository> <subtree> --commit <hash>\n\n" ~
	"Run from the Jujutsu workspace that will own the subtree.";

int main(string[] args) {
	try {
		if (args.length == 2 && (args[1] == "-h" || args[1] == "--help")) {
			writeln(USAGE);
			return 0;
		}

		syncSubtree(parseOptions(args));
		return 0;
	}
	catch (Exception error) {
		stderr.writeln("sync-subtree: ", error.msg);
		return 1;
	}
}

private Options parseOptions(string[] args) {
	enforce(args.length == 3 || args.length == 5, USAGE);

	Options options;
	options.repository = args[1];
	options.subtree = normalizeSubtree(args[2]);
	enforce(options.repository.length, "repository cannot be empty");

	if (args.length == 3)
		return options;

	options.source = args[4];
	enforce(options.source.length, args[3] ~ " requires a value");

	switch (args[3]) {
	case "--branch":
		options.sourceKind = SourceKind.branch;
		break;
	case "--commit":
		options.sourceKind = SourceKind.commit;
		enforce(options.source.length >= 8 && options.source.length <= 64,
			"commit must be an 8-64 character hexadecimal object ID");
		enforce(options.source.all!isHexDigit,
			"commit must be an 8-64 character hexadecimal object ID");
		break;
	default:
		throw new Exception("unknown option " ~ args[3] ~ "\n\n" ~ USAGE);
	}

	return options;
}

private string normalizeSubtree(string subtree) {
	subtree = subtree.replace('\\', '/');
	enforce(subtree.length && !isAbsolute(subtree) && !subtree.startsWith("/"),
		"subtree must be a relative repository path");
	enforce(!subtree.endsWith("/"), "subtree must not end with '/'");

	foreach (component; subtree.split('/')) {
		enforce(component.length && component != "." && component != "..",
			"subtree must not contain empty, '.' or '..' components");
		enforce(component != ".jj" && component != ".git",
			"subtree must not point inside repository metadata");
		foreach (character; component)
			enforce(character >= ' ', "subtree must not contain control characters");
	}

	return subtree;
}

private void syncSubtree(Options options) {
	string workspaceRoot = queryCommand(["jj", "--quiet", "root"]).strip.idup;
	enforce(workspaceRoot.length, "jj root returned an empty path");

	string currentCommit = queryRevision(workspaceRoot, "@");
	string lastSync = findLastSync(workspaceRoot, options.subtree);
	string target = buildPath(workspaceRoot, options.subtree.replace("/", dirSeparator));
	bool targetExists = pathExists(target);
	string[] currentEntries = fileEntries(workspaceRoot, currentCommit, options.subtree);
	bool isLegacyGitlink = currentEntries.length == 1 &&
		currentEntries[0] == options.subtree ~ "\tgit-submodule";
	bool isResumingSync = lastSync == currentCommit && isLegacyGitlink;

	if (!lastSync.length) {
		enforce(!targetExists && (!currentEntries.length || isLegacyGitlink),
			format("'%s' has content but no prior Sync revision to use as its local-patch base",
				options.subtree));
	}

	string metadataRoot = buildPath(workspaceRoot, ".jj");
	enforce(metadataRoot.isDir, "workspace .jj metadata directory was not found");
	string stagingRoot = buildPath(metadataRoot, "sync-subtree-" ~ randomUUID().to!string);
	string exportRoot = buildPath(stagingRoot, "upstream");
	mkdir(stagingRoot);
	bool succeeded;
	scope (exit) {
		if (succeeded && pathExists(stagingRoot))
			stagingRoot.rmdirRecurse;
	}
	scope (failure) {
		if (pathExists(stagingRoot))
			stderr.writeln("sync-subtree: staging data retained at ", stagingRoot);
	}

	writeln("Fetching upstream repository...");
	stdout.flush;
	string[] cloneCommand = [
		"jj", "--no-pager", "--color", "never", "git", "clone", "--no-colocate",
	];
	if (options.sourceKind == SourceKind.commit) {
		cloneCommand ~= ["--fetch-tags", "all"];
	}
	else {
		cloneCommand ~= ["--depth", "1", "--fetch-tags", "none"];
		if (options.sourceKind == SourceKind.branch)
			cloneCommand ~= ["--branch", options.source];
	}
	cloneCommand ~= ["--", options.repository, exportRoot];
	runCommand(cloneCommand);

	string upstreamCommit;
	if (options.sourceKind == SourceKind.commit)
		upstreamCommit = queryRevision(exportRoot, options.source);
	else {
		upstreamCommit = queryRevision(exportRoot, "@-");
		if (options.sourceKind == SourceKind.defaultBranch && upstreamCommit.all!(c => c == '0'))
			upstreamCommit = queryRevision(exportRoot,
				"remote_bookmarks(remote=\"origin\")");
	}
	enforce(!upstreamCommit.all!(c => c == '0'),
		"the upstream revision resolved to Jujutsu's root commit; choose --branch or --commit");

	// Check out the selected tree without editing the immutable upstream commit.
	runJJ(exportRoot, ["new", "-m", "sync-subtree export", upstreamCommit]);
	string[] upstreamEntries = fileEntries(exportRoot, upstreamCommit);
	string syncTitle = format("Sync '%s' from commit %s",
		options.subtree, upstreamCommit[0 .. 8]);

	string patchChange;
	if (lastSync.length && !isResumingSync) {
		string marker = "sync-subtree temporary patch " ~ randomUUID().to!string;
		runJJ(workspaceRoot, ["new", "--no-edit", "-m", marker, lastSync]);
		patchChange = findRevisionByTitle(workspaceRoot,
			"children(" ~ lastSync ~ ")", marker);
		runJJ(workspaceRoot, [
			"restore", "--from", currentCommit, "--into", patchChange,
			"--", rootFileset(options.subtree),
		]);
	}

	if (isResumingSync)
		runJJ(workspaceRoot, ["describe", "-r", "@", "-m", syncTitle]);
	else
		runJJ(workspaceRoot, ["new", "-m", syncTitle, currentCommit]);
	string cloneMetadata = buildPath(exportRoot, ".jj");
	enforce(cloneMetadata.isDir, "temporary clone has no .jj metadata directory");
	cloneMetadata.rmdirRecurse;

	string targetParent = target.dirName;
	if (!pathExists(targetParent))
		targetParent.mkdirRecurse;
	else
		enforce(targetParent.isDir, "subtree parent is not a directory: " ~ targetParent);
	string backup = buildPath(stagingRoot, "previous-subtree");
	if (pathExists(target))
		target.rename(backup);
	// Remove a legacy Gitlink before tracking the fetched checkout as ordinary files.
	runJJ(workspaceRoot, [
		"restore", "--from", "root()", "--into", "@",
		"--", rootFileset(options.subtree),
	]);
	try {
		exportRoot.rename(target);
	}
	catch (Exception error) {
		if (pathExists(backup) && !pathExists(target))
			backup.rename(target);
		throw error;
	}

	// Explicit tracking also imports upstream files ignored by the parent repository.
	runJJ(workspaceRoot, [
		"file", "track", "--include-ignored", "--", rootFileset(options.subtree),
	]);
	string syncCommit = queryRevision(workspaceRoot, "@");
	verifyImportedTree(workspaceRoot, syncCommit, options.subtree, upstreamEntries);

	string patchTitle = "Apply local patches to '" ~ options.subtree ~ "'";
	if (patchChange.length) {
		runJJ(workspaceRoot, ["rebase", "-s", patchChange, "-d", syncCommit]);
		runJJ(workspaceRoot, ["describe", "-r", patchChange, "-m", patchTitle]);
		runJJ(workspaceRoot, ["new", patchChange]);
	}
	else {
		runJJ(workspaceRoot, ["new", syncCommit]);
	}

	writeln(syncTitle);
	if (patchChange.length) {
		string conflicts = queryJJ(workspaceRoot, [
			"resolve", "--list", "-r", patchChange, "--", rootFileset(options.subtree),
		]).strip.idup;
		if (conflicts.length)
			writeln("Local patches applied with conflicts:\n", conflicts);
		else
			writeln("Local patches applied cleanly.");
	}
	succeeded = true;
}

private string findLastSync(string workspaceRoot, string subtree) {
	string prefix = "Sync '" ~ subtree ~ "' from commit ";
	string history = queryJJ(workspaceRoot, [
		"log", "-r", "first_ancestors(@)", "--no-graph",
		"-T", "commit_id ++ \"\\t\" ++ description.first_line() ++ \"\\n\"",
	]);

	foreach (line; history.splitLines) {
		size_t separator = line.indexOf('\t');
		if (separator == -1)
			continue;
		string title = line[separator + 1 .. $];
		if (isSyncTitle(title, prefix))
			return line[0 .. separator].idup;
	}

	return null;
}

private bool isSyncTitle(string title, string prefix) {
	if (!title.startsWith(prefix))
		return false;
	string commit = title[prefix.length .. $];
	return commit.length == 8 && commit.all!isHexDigit;
}

private string findRevisionByTitle(string workspaceRoot, string revset, string title) {
	string history = queryJJ(workspaceRoot, [
		"log", "-r", revset, "--no-graph",
		"-T", "change_id ++ \"\\t\" ++ description.first_line() ++ \"\\n\"",
	]);
	string result;
	foreach (line; history.splitLines) {
		size_t separator = line.indexOf('\t');
		if (separator == -1 || line[separator + 1 .. $] != title)
			continue;
		enforce(!result.length, "temporary patch revision was not unique");
		result = line[0 .. separator].idup;
	}
	enforce(result.length, "could not find the temporary patch revision");
	return result;
}

private string queryRevision(string repository, string revset) {
	string output = queryJJ(repository, [
		"log", "-r", revset, "--no-graph", "-T", "commit_id ++ \"\\n\"",
	]);
	string[] revisions;
	foreach (line; output.splitLines) {
		if (line.length)
			revisions ~= line.idup;
	}
	enforce(revisions.length == 1,
		format("revision '%s' resolved to %s commits", revset, revisions.length));
	return revisions[0];
}

private string[] fileEntries(string repository, string revision, string subtree = null) {
	string[] arguments = [
		"file", "list", "-r", revision,
		"-T", "path ++ \"\\t\" ++ self.file_type() ++ \"\\n\"",
	];

	string[] entries;
	foreach (line; queryJJ(repository, arguments).splitLines) {
		if (!line.length)
			continue;
		size_t separator = line.lastIndexOf('\t');
		enforce(separator != -1, "jj file list returned an invalid entry");
		string path = line[0 .. separator];
		if (!subtree.length || path == subtree || path.startsWith(subtree ~ "/"))
			entries ~= line.idup;
	}
	return entries;
}

private string rootFileset(string subtree) {
	return "root:\"" ~ subtree.replace("\\", "\\\\").replace("\"", "\\\"") ~ "\"";
}

private void verifyImportedTree(string workspaceRoot, string syncCommit,
	string subtree, string[] upstreamEntries) {
	string[] expected;
	foreach (entry; upstreamEntries)
		expected ~= subtree ~ "/" ~ entry;
	string[] actual = fileEntries(workspaceRoot, syncCommit, subtree);
	enforce(expected == actual,
		format("the imported '%s' tree differs from upstream; the Sync revision was left for inspection",
			subtree));
}

private bool pathExists(string path) {
	if (path.exists)
		return true;
	try {
		return path.isSymlink;
	}
	catch (Exception) {
		return false;
	}
}

private string queryJJ(string repository, string[] arguments) {
	return queryCommand([
		"jj", "--quiet", "--no-pager", "--color", "never", "-R", repository,
	] ~ arguments);
}

private void runJJ(string repository, string[] arguments) {
	runCommand([
		"jj", "--no-pager", "--color", "never", "-R", repository,
	] ~ arguments);
}

private string queryCommand(string[] arguments) {
	auto result = execute(arguments, null, Config.stderrPassThrough);
	string error = result.output.strip.idup;
	if (!error.length)
		error = "command failed: " ~ arguments[0];
	enforce(result.status == 0, error);
	return result.output;
}

private void runCommand(string[] arguments) {
	string output = queryCommand(arguments).strip.idup;
	if (output.length)
		writeln(output);
}

unittest {
	assert(normalizeSubtree("repo/subrepo") == "repo/subrepo");
	assert(normalizeSubtree("repo\\subrepo") == "repo/subrepo");
	assert(isSyncTitle("Sync 'repo/subrepo' from commit 1234abcd",
		"Sync 'repo/subrepo' from commit "));
	assert(!isSyncTitle("Sync 'repo/subrepo' from commit main",
		"Sync 'repo/subrepo' from commit "));
}
