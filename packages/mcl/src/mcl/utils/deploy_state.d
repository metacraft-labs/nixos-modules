module mcl.utils.deploy_state;

import std.algorithm : canFind, filter, map, sort;
import std.array : array;
import std.conv : to;
import std.exception : enforce;
import std.file : dirEntries, exists, mkdirRecurse, readText, remove, rename,
    setAttributes, SpanMode, write;
import std.json : JSONOptions, JSONValue, parseJSON;
import std.path : baseName, buildPath, dirName;
import std.string : endsWith, split, toStringz;
import std.typecons : Nullable;
import std.uuid : randomUUID;

import mcl.utils.deploy_manifest : manifestDeploymentId, manifestDesiredSystemPath,
    manifestSequence, manifestTarget;
import mcl.utils.deployment_events : utcTimestamp;

version (Posix)
{
    import core.sys.posix.fcntl : FD_CLOEXEC, F_GETFD, F_SETFD, O_CREAT,
        O_NOFOLLOW, O_NONBLOCK, O_RDONLY, O_RDWR, fcntl, open;
    import core.sys.posix.sys.stat : fstat, mode_t, S_ISDIR, S_ISREG, stat, stat_t;
    import core.sys.posix.sys.types : uid_t;
    import core.sys.posix.unistd : close, geteuid;

    extern (C) @trusted nothrow @nogc
    {
        int openat(int directoryFd, const scope char* path, int flags, ...);
        int mkdirat(int directoryFd, const scope char* path, mode_t mode);
    }

    version (linux)
    {
        import core.sys.posix.fcntl : O_CLOEXEC, O_DIRECTORY;
        import core.sys.linux.sys.file : LOCK_EX, LOCK_NB, LOCK_UN, flock;
    }
    else version (OSX)
    {
        // Druntime's Darwin fcntl bindings omit these non-POSIX flags.
        enum O_DIRECTORY = 0x00100000;
        enum O_CLOEXEC = 0x01000000;
        enum LOCK_EX = 0x02;
        enum LOCK_NB = 0x04;
        enum LOCK_UN = 0x08;
        extern (C) int flock(int fd, int operation) @trusted;
    }
    else
        static assert(false,
            "Deployment target state locking is not implemented for this POSIX platform.");
}

alias DurableManifestValidator = void delegate(JSONValue manifest);

struct DurableManifestSnapshot
{
    bool present;
    string bytes;
    JSONValue manifest;
}

enum DesiredManifestDecision
{
    accepted,
    idempotent,
    superseded,
    conflict,
}

final class DeployTargetStateLock
{
    version (Posix)
    {
        private int fd = -1;
    }

    private this(int acquiredFd, string path)
    {
        version (Posix)
        {
            fd = acquiredFd;
            if (flock(fd, LOCK_EX) != 0)
            {
                close(fd);
                fd = -1;
                throw new Exception("Could not acquire deployment state lock: " ~ path);
            }
        }
        else
        {
            static assert(false,
                "Deployment target state locking is not implemented for this platform.");
        }
    }

    ~this()
    {
        release();
    }

    void release()
    {
        version (Posix)
        {
            if (fd >= 0)
            {
                flock(fd, LOCK_UN);
                close(fd);
                fd = -1;
            }
        }
    }
}

version (Posix)
{
    private enum stateDirectoryCreateMode = cast(mode_t) 488; // 0750
    private enum locksDirectoryCreateMode = cast(mode_t) 448; // 0700
    private enum lockFileMode = cast(mode_t) 384; // 0600
    private enum permissionBits = cast(mode_t) 511; // 0777
    private enum groupOrOtherWriteBits = cast(mode_t) 18; // 0022

    private void ensureCloseOnExec(int fd, string description)
    {
        auto flags = fcntl(fd, F_GETFD);
        enforce(flags >= 0, "Could not inspect close-on-exec for " ~ description ~ ".");
        if ((flags & FD_CLOEXEC) == 0)
            enforce(fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0,
                "Could not make " ~ description ~ " close-on-exec.");
        flags = fcntl(fd, F_GETFD);
        enforce(flags >= 0 && (flags & FD_CLOEXEC) != 0,
            "Could not verify close-on-exec for " ~ description ~ ".");
    }

    private stat_t descriptorMetadata(int fd, string description)
    {
        stat_t metadata;
        enforce(fstat(fd, &metadata) == 0,
            "Could not inspect " ~ description ~ ".");
        return metadata;
    }

    private void validateDirectoryDescriptor(
        int fd,
        string description,
        uid_t expectedOwner,
        bool requireExactMode = false,
        mode_t exactMode = cast(mode_t) 0,
    )
    {
        auto metadata = descriptorMetadata(fd, description);
        enforce(S_ISDIR(metadata.st_mode), description ~ " is not a directory.");
        enforce(metadata.st_uid == expectedOwner,
            description ~ " is not owned by the effective deployment user.");
        if (requireExactMode)
            enforce((metadata.st_mode & permissionBits) == exactMode,
                description ~ " does not have mode 0700.");
        else
            enforce((metadata.st_mode & groupOrOtherWriteBits) == 0,
                description ~ " is writable by its group or other users.");
    }

    private void validateLockDescriptor(
        int fd,
        string description,
        uid_t expectedOwner,
    )
    {
        auto metadata = descriptorMetadata(fd, description);
        enforce(S_ISREG(metadata.st_mode),
            description ~ " is not a regular file.");
        enforce(metadata.st_nlink == 1,
            description ~ " has more than one hard link.");
        enforce(metadata.st_uid == expectedOwner,
            description ~ " is not owned by the effective deployment user.");
        enforce((metadata.st_mode & permissionBits) == lockFileMode,
            description ~ " does not have mode 0600.");
    }

    private string[] securePathComponents(string path)
    {
        enforce(path != "", "Deployment state directory must not be empty.");
        auto components = path
            .split("/")
            .filter!(component => component != "" && component != ".")
            .array;
        enforce(components.length > 0,
            "Deployment state directory must name a directory other than the filesystem root.");
        enforce(!components.canFind(".."),
            "Deployment state directory must not contain '..' path components.");
        return components;
    }

    private int openOrCreateStateDirectory(string stateDir, uid_t expectedOwner)
    {
        securePathComponents(stateDir);
        auto parentPath = stateDir.dirName;
        auto childName = stateDir.baseName;
        enforce(childName != "" && childName != "." && childName != ".."
                && !childName.canFind("/"),
            "Deployment state directory has an unsafe final path component.");

        // The state directory is application-owned, but its conventional
        // ancestors may contain platform-managed symlinks (for example
        // Darwin's /var -> /private/var). Bind the immediate parent after
        // creating any missing ancestors, then create/open only the final
        // state component relative to that descriptor.
        mkdirRecurse(parentPath);
        auto parentFd = open(
            parentPath.toStringz,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
        );
        enforce(parentFd >= 0,
            "Could not securely open deployment state directory parent: " ~ parentPath);
        scope(exit) close(parentFd);
        ensureCloseOnExec(parentFd, "deployment state directory parent " ~ parentPath);

        auto stateFd = openat(
            parentFd,
            childName.toStringz,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
        );
        if (stateFd < 0)
        {
            enforce(mkdirat(parentFd, childName.toStringz, stateDirectoryCreateMode) == 0,
                "Could not securely create deployment state directory " ~ stateDir ~ ".");
            stateFd = openat(
                parentFd,
                childName.toStringz,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
            );
        }
        enforce(stateFd >= 0,
            "Could not securely open deployment state directory " ~ stateDir ~ ".");
        scope(failure) close(stateFd);
        ensureCloseOnExec(stateFd, "deployment state directory " ~ stateDir);

        validateDirectoryDescriptor(
            stateFd,
            "Deployment state directory " ~ stateDir,
            expectedOwner,
        );
        return stateFd;
    }

    private int openOrCreateLocksDirectory(
        int stateFd,
        string stateDir,
        uid_t expectedOwner,
    )
    {
        enum childName = "locks";
        auto locksFd = openat(
            stateFd,
            childName.toStringz,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
        );
        if (locksFd < 0)
        {
            enforce(mkdirat(stateFd, childName.toStringz, locksDirectoryCreateMode) == 0,
                "Could not securely create deployment locks directory in " ~ stateDir ~ ".");
            locksFd = openat(
                stateFd,
                childName.toStringz,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
            );
        }
        enforce(locksFd >= 0,
            "Could not securely open deployment locks directory in " ~ stateDir ~ ".");
        scope(failure) close(locksFd);
        ensureCloseOnExec(locksFd, "deployment locks directory in " ~ stateDir);
        validateDirectoryDescriptor(
            locksFd,
            "Deployment locks directory in " ~ stateDir,
            expectedOwner,
            true,
            locksDirectoryCreateMode,
        );
        return locksFd;
    }
}

string safePathComponent(string value)
{
    string result;
    foreach (ch; value)
    {
        const ok = (ch >= 'a' && ch <= 'z')
            || (ch >= 'A' && ch <= 'Z')
            || (ch >= '0' && ch <= '9')
            || ch == '.'
            || ch == '_'
            || ch == '-';
        result ~= ok ? ch : '_';
    }
    return result == "" ? "unknown" : result;
}

string safeTargetName(string target) => safePathComponent(target);

void ensureDeployStateDirs(string stateDir)
{
    foreach (name; [
        "desired",
        "current",
        "failed",
        "superseded",
        "converged",
        "targets",
        "agent-status",
    ])
        mkdirRecurse(stateDir.buildPath(name));
}

string manifestStatePath(string stateDir, string category, string deploymentId)
{
    return stateDir.buildPath(category, safePathComponent(deploymentId) ~ ".json");
}

string targetLatestPath(string stateDir, string target)
{
    return stateDir.buildPath("targets", safeTargetName(target) ~ ".json");
}

string targetStateLockPath(string stateDir, string target)
{
    return stateDir.buildPath("locks", targetStateLockName(target));
}

private string targetStateLockName(string target)
{
    auto name = safeTargetName(target) ~ ".state.lock";
    enforce(name != "." && name != ".." && !name.canFind("/"),
        "Deployment target produced an unsafe state-lock filename.");
    return name;
}

DeployTargetStateLock acquireDeployTargetStateLock(string stateDir, string target)
{
    version (Posix)
    {
        auto expectedOwner = geteuid();
        return acquireDeployTargetStateLockForExpectedOwners(
            stateDir,
            target,
            expectedOwner,
            expectedOwner,
            expectedOwner,
        );
    }
    else
    {
        static assert(false,
            "Deployment target state locking is not implemented for this platform.");
    }
}

version (Posix)
private DeployTargetStateLock acquireDeployTargetStateLockForExpectedOwners(
    string stateDir,
    string target,
    uid_t expectedStateOwner,
    uid_t expectedLocksOwner,
    uid_t expectedLockOwner,
)
{
    auto stateFd = openOrCreateStateDirectory(stateDir, expectedStateOwner);
    scope(exit) close(stateFd);
    auto locksFd = openOrCreateLocksDirectory(stateFd, stateDir, expectedLocksOwner);
    scope(exit) close(locksFd);

    auto lockName = targetStateLockName(target);
    auto lockPath = targetStateLockPath(stateDir, target);
    auto lockFd = openat(
        locksFd,
        lockName.toStringz,
        O_CREAT | O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
        lockFileMode,
    );
    enforce(lockFd >= 0,
        "Could not securely open deployment state lock: " ~ lockPath);
    scope(failure)
        if (lockFd >= 0)
            close(lockFd);

    ensureCloseOnExec(lockFd, "deployment state lock " ~ lockPath);
    validateLockDescriptor(
        lockFd,
        "Deployment state lock " ~ lockPath,
        expectedLockOwner,
    );
    auto ownedFd = lockFd;
    lockFd = -1;
    return new DeployTargetStateLock(ownedFd, lockPath);
}

Nullable!JSONValue loadManifestFile(string path)
{
    if (!path.exists)
        return Nullable!JSONValue.init;
    return Nullable!JSONValue(path.readText.parseJSON);
}

Nullable!JSONValue loadLatestManifest(string stateDir, string target)
{
    return loadManifestFile(targetLatestPath(stateDir, target));
}

DurableManifestSnapshot loadDurableManifestSnapshot(
    string stateDir,
    string target,
    DurableManifestValidator validate = null,
)
{
    auto path = targetLatestPath(stateDir, target);
    if (!path.exists)
        return DurableManifestSnapshot(present: false);

    auto bytes = path.readText;
    auto manifest = bytes.parseJSON;
    if (validate !is null)
        validate(manifest);
    return DurableManifestSnapshot(
        present: true,
        bytes: bytes,
        manifest: manifest,
    );
}

void enforceDurableManifestSnapshotCurrent(
    string stateDir,
    string target,
    DurableManifestSnapshot snapshot,
)
{
    auto path = targetLatestPath(stateDir, target);
    if (!snapshot.present)
    {
        enforce(!path.exists,
            "Durable latest-target state changed after validation.");
        return;
    }

    enforce(path.exists && path.readText == snapshot.bytes,
        "Durable latest-target state changed after validation.");
}

void writeLatestManifestAtomically(string stateDir, string target, string manifestBytes)
{
    auto path = targetLatestPath(stateDir, target);
    auto temporary = path ~ ".tmp-" ~ randomUUID.toString;
    scope(failure)
        if (temporary.exists)
            temporary.remove;

    temporary.write(manifestBytes);
    version (Posix)
        temporary.setAttributes(416);
    temporary.rename(path);
}

JSONValue supersededStateFor(JSONValue manifest)
{
    return JSONValue([
        "deploymentId": JSONValue(manifestDeploymentId(manifest)),
        "sequence": JSONValue(cast(long) manifestSequence(manifest)),
        "supersededAt": JSONValue(utcTimestamp()),
    ]);
}

Nullable!JSONValue supersededStateForLatest(string stateDir, string target, ulong newSequence)
{
    auto latest = loadLatestManifest(stateDir, target);
    if (latest.isNull)
        return Nullable!JSONValue.init;

    if (manifestSequence(latest.get) >= newSequence)
        throw new Exception(
            "Desired deployment sequence " ~ newSequence.to!string
            ~ " is not newer than latest sequence "
            ~ manifestSequence(latest.get).to!string
            ~ " for target " ~ target
        );

    return Nullable!JSONValue(supersededStateFor(latest.get));
}

JSONValue statusJson(JSONValue manifest, string state, string message = "")
{
    JSONValue[string] status = [
        "target": JSONValue(manifestTarget(manifest)),
        "deploymentId": JSONValue(manifestDeploymentId(manifest)),
        "sequence": JSONValue(cast(long) manifestSequence(manifest)),
        "desiredSystemPath": JSONValue(manifestDesiredSystemPath(manifest)),
        "currentState": JSONValue(state),
        "updatedAt": JSONValue(utcTimestamp()),
    ];
    if (message != "")
        status["message"] = JSONValue(message);
    return JSONValue(status);
}

void writeManifest(string stateDir, string category, JSONValue manifest)
{
    ensureDeployStateDirs(stateDir);
    manifestStatePath(stateDir, category, manifestDeploymentId(manifest))
        .write(manifest.toString(JSONOptions.doNotEscapeSlashes));
}

void writeStatus(string stateDir, string category, JSONValue manifest, string state, string message = "")
{
    ensureDeployStateDirs(stateDir);
    manifestStatePath(stateDir, category, manifestDeploymentId(manifest))
        .write(statusJson(manifest, state, message).toString(JSONOptions.doNotEscapeSlashes));
}

DesiredManifestDecision recordDesiredManifestBound(
    string stateDir,
    JSONValue manifest,
    string manifestBytes,
    DurableManifestSnapshot durableLatest,
)
{
    auto target = manifestTarget(manifest);
    enforceDurableManifestSnapshotCurrent(stateDir, target, durableLatest);
    enforce(manifestBytes.parseJSON == manifest,
        "Bound manifest bytes do not match the validated desired manifest.");

    if (durableLatest.present)
    {
        auto durableSequence = manifestSequence(durableLatest.manifest);
        auto incomingSequence = manifestSequence(manifest);
        if (incomingSequence < durableSequence)
            return DesiredManifestDecision.superseded;
        if (incomingSequence == durableSequence)
            return durableLatest.bytes == manifestBytes
                ? DesiredManifestDecision.idempotent
                : DesiredManifestDecision.conflict;
    }

    // No desired/current/high-water state is written until the complete
    // sequence and exact-byte identity decision above has succeeded.
    ensureDeployStateDirs(stateDir);
    writeManifest(stateDir, "desired", manifest);
    if (durableLatest.present)
        writeStatus(stateDir, "superseded", durableLatest.manifest, "superseded",
            "Superseded by " ~ manifestDeploymentId(manifest) ~ ".");

    writeLatestManifestAtomically(stateDir, target, manifestBytes);
    writeStatus(stateDir, "current", manifest, "accepted");
    return DesiredManifestDecision.accepted;
}

bool recordDesiredManifest(string stateDir, JSONValue manifest)
{
    auto target = manifestTarget(manifest);
    auto stateLock = acquireDeployTargetStateLock(stateDir, target);
    scope(exit) stateLock.release();
    auto durableLatest = loadDurableManifestSnapshot(stateDir, target);
    auto manifestBytes = manifest.toString(JSONOptions.doNotEscapeSlashes);
    auto decision = recordDesiredManifestBound(
        stateDir, manifest, manifestBytes, durableLatest);
    return decision == DesiredManifestDecision.accepted
        || decision == DesiredManifestDecision.idempotent;
}

void markDeploymentState(string stateDir, JSONValue manifest, string state, string message = "")
{
    const category = state == "succeeded" ? "converged"
        : state == "failed" ? "failed"
        : state == "superseded" ? "superseded"
        : "current";
    writeStatus(stateDir, category, manifest, state, message);
}

JSONValue[] loadLatestManifests(string stateDir, string[] selectedTargets = null)
{
    ensureDeployStateDirs(stateDir);
    JSONValue[] result;
    auto selected = selectedTargets;

    foreach (entry; dirEntries(stateDir.buildPath("targets"), SpanMode.shallow))
    {
        if (!entry.name.endsWith(".json"))
            continue;
        auto manifest = entry.name.readText.parseJSON;
        if (selected.length == 0 || selected.canFind(manifestTarget(manifest)))
            result ~= manifest;
    }

    return result
        .sort!((a, b) => manifestTarget(a) < manifestTarget(b))
        .array;
}

version (Posix)
{
    private bool openDescriptorReferencesPathForLockTest(string path)
    {
        if (!path.exists)
            return false;
        stat_t pathMetadata;
        if (stat(path.toStringz, &pathMetadata) != 0)
            return false;
        foreach (fd; 0 .. 4096)
        {
            stat_t descriptor;
            if (fstat(fd, &descriptor) == 0
                && descriptor.st_dev == pathMetadata.st_dev
                && descriptor.st_ino == pathMetadata.st_ino)
                return true;
        }
        return false;
    }

    private void assertLockAcquireRejectedWithoutFdLeak(
        string stateDir,
        string target,
        uid_t expectedLocksOwner,
        uid_t expectedLockOwner,
    )
    {
        bool rejected;
        try
        {
            auto unexpected = acquireDeployTargetStateLockForExpectedOwners(
                stateDir,
                target,
                geteuid(),
                expectedLocksOwner,
                expectedLockOwner,
            );
            unexpected.release();
        }
        catch (Exception)
        {
            rejected = true;
        }
        assert(rejected, "Unsafe deployment lock fixture was accepted.");
        foreach (path; [
            stateDir,
            stateDir.buildPath("locks"),
            targetStateLockPath(stateDir, target),
        ])
            assert(!openDescriptorReferencesPathForLockTest(path),
                "Rejected deployment lock acquisition leaked a descriptor for " ~ path ~ ".");
    }
}

@("test_deploy_state_lock_rejects_locks_parent_symlink_without_mutating_target")
unittest
{
    version (Posix)
    {
        import std.file : deleteme, getAttributes, isSymlink, mkdirRecurse,
            readText, remove, rmdirRecurse, setAttributes, symlink, write;

        auto root = deleteme ~ ".deploy-lock-parent-symlink";
        auto stateDir = root.buildPath("state");
        auto locksPath = stateDir.buildPath("locks");
        auto outside = root.buildPath("outside");
        auto sentinel = outside.buildPath("sentinel");
        scope(exit)
        {
            if (locksPath.isSymlink)
                locksPath.remove;
            if (root.exists)
                root.rmdirRecurse;
        }

        stateDir.mkdirRecurse;
        stateDir.setAttributes(493);
        outside.mkdirRecurse;
        sentinel.write("outside-bytes");
        sentinel.setAttributes(384);
        outside.symlink(locksPath);

        auto sentinelMode = sentinel.getAttributes & 511;
        assertLockAcquireRejectedWithoutFdLeak(
            stateDir,
            "target",
            geteuid(),
            geteuid(),
        );
        assert(sentinel.readText == "outside-bytes");
        assert((sentinel.getAttributes & 511) == sentinelMode);
        assert(!outside.buildPath("target.state.lock").exists);
    }
}

@("test_deploy_state_lock_rejects_leaf_symlink_without_mutating_target")
unittest
{
    version (Posix)
    {
        import std.file : deleteme, getAttributes, isSymlink, mkdirRecurse,
            readText, remove, rmdirRecurse, setAttributes, symlink, write;

        auto root = deleteme ~ ".deploy-lock-leaf-symlink";
        auto stateDir = root.buildPath("state");
        auto locksDir = stateDir.buildPath("locks");
        auto lockPath = targetStateLockPath(stateDir, "target");
        auto outside = root.buildPath("outside");
        scope(exit)
        {
            if (lockPath.isSymlink)
                lockPath.remove;
            if (root.exists)
                root.rmdirRecurse;
        }

        locksDir.mkdirRecurse;
        stateDir.setAttributes(493);
        locksDir.setAttributes(448);
        outside.write("outside-bytes");
        outside.setAttributes(384);
        outside.symlink(lockPath);

        auto outsideMode = outside.getAttributes & 511;
        assertLockAcquireRejectedWithoutFdLeak(
            stateDir,
            "target",
            geteuid(),
            geteuid(),
        );
        assert(outside.readText == "outside-bytes");
        assert((outside.getAttributes & 511) == outsideMode);
    }
}

@("test_deploy_state_lock_rejects_nonregular_hardlinked_permissive_and_wrong_owner")
unittest
{
    version (Posix)
    {
        import core.sys.posix.sys.stat : mkfifo;
        import core.sys.posix.unistd : link;
        import std.file : deleteme, getAttributes, mkdirRecurse, remove,
            rmdirRecurse, setAttributes, write;

        auto root = deleteme ~ ".deploy-lock-invalid-inodes";
        auto stateDir = root.buildPath("state");
        auto locksDir = stateDir.buildPath("locks");
        scope(exit)
            if (root.exists)
                root.rmdirRecurse;

        locksDir.mkdirRecurse;
        stateDir.setAttributes(493);
        locksDir.setAttributes(448);

        auto fifoPath = targetStateLockPath(stateDir, "fifo");
        assert(mkfifo(fifoPath.toStringz, lockFileMode) == 0);
        assertLockAcquireRejectedWithoutFdLeak(
            stateDir,
            "fifo",
            geteuid(),
            geteuid(),
        );
        fifoPath.remove;

        auto hardlinkSource = root.buildPath("hardlink-source");
        auto hardlinkPath = targetStateLockPath(stateDir, "hardlink");
        hardlinkSource.write("hardlink-bytes");
        hardlinkSource.setAttributes(384);
        assert(link(hardlinkSource.toStringz, hardlinkPath.toStringz) == 0);
        assertLockAcquireRejectedWithoutFdLeak(
            stateDir,
            "hardlink",
            geteuid(),
            geteuid(),
        );
        assert(hardlinkSource.readText == "hardlink-bytes");
        hardlinkPath.remove;

        auto permissivePath = targetStateLockPath(stateDir, "permissive");
        permissivePath.write("");
        permissivePath.setAttributes(420);
        assertLockAcquireRejectedWithoutFdLeak(
            stateDir,
            "permissive",
            geteuid(),
            geteuid(),
        );
        assert((permissivePath.getAttributes & 511) == 420);
        permissivePath.remove;

        auto locksModeBefore = locksDir.getAttributes & 511;
        foreach (mode; [488, 320, 511]) // 0750, 0500, 0777
        {
            locksDir.setAttributes(mode);
            assertLockAcquireRejectedWithoutFdLeak(
                stateDir,
                "directory-mode-" ~ mode.to!string,
                geteuid(),
                geteuid(),
            );
            assert((locksDir.getAttributes & 511) == mode);
        }
        locksDir.setAttributes(locksModeBefore);

        auto actualOwner = geteuid();
        auto wrongOwner = actualOwner == uid_t.max
            ? cast(uid_t) (actualOwner - 1)
            : cast(uid_t) (actualOwner + 1);
        assertLockAcquireRejectedWithoutFdLeak(
            stateDir,
            "wrong-locks-owner",
            wrongOwner,
            actualOwner,
        );
        assertLockAcquireRejectedWithoutFdLeak(
            stateDir,
            "wrong-lock-owner",
            actualOwner,
            wrongOwner,
        );
    }
}

@("test_deploy_state_lock_is_cloexec_sanitized_and_idempotently_released")
unittest
{
    version (Posix)
    {
        import std.file : deleteme, rmdirRecurse;

        auto stateDir = deleteme ~ ".deploy-lock-cloexec.state";
        scope(exit)
            if (stateDir.exists)
                stateDir.rmdirRecurse;

        auto stateLock = acquireDeployTargetStateLock(stateDir, "../../nested/target");
        assert(stateLock.fd >= 0);
        auto descriptorFlags = fcntl(stateLock.fd, F_GETFD);
        assert(descriptorFlags >= 0 && (descriptorFlags & FD_CLOEXEC) != 0);
        assert(targetStateLockPath(stateDir, "../../nested/target").exists);
        assert(!stateDir.buildPath("nested").exists);
        stateLock.release();
        stateLock.release();
        assert(stateLock.fd == -1);
    }
}

@("test_deploy_state_lock_creates_exact_0700_locks_directory_under_default_umask")
unittest
{
    version (Posix)
    {
        import core.sys.posix.sys.stat : umask;
        import std.file : deleteme, getAttributes, rmdirRecurse;

        auto stateDir = deleteme ~ ".deploy-lock-default-umask.state";
        scope(exit)
            if (stateDir.exists)
                stateDir.rmdirRecurse;

        auto previousUmask = umask(cast(mode_t) 18); // conventional 0022
        scope(exit) umask(previousUmask);

        // Generic state preparation deliberately leaves the security-sensitive
        // locks child absent. The descriptor-safe acquisition path owns its
        // creation so a caller's umask can never produce the legacy 0755 mode.
        ensureDeployStateDirs(stateDir);
        auto locksDir = stateDir.buildPath("locks");
        assert(!locksDir.exists);

        auto stateLock = acquireDeployTargetStateLock(stateDir, "target");
        scope(exit) stateLock.release();
        assert(locksDir.exists);
        assert((locksDir.getAttributes & 511) == 448);
    }
}

@("test_deploy_state_lock_serializes_independent_open_file_descriptions")
unittest
{
    version (Posix)
    {
        import std.file : deleteme, rmdirRecurse;

        auto stateDir = deleteme ~ ".deploy-lock-serialization.state";
        scope(exit)
            if (stateDir.exists)
                stateDir.rmdirRecurse;

        auto first = acquireDeployTargetStateLock(stateDir, "target");
        scope(exit) first.release();
        auto lockPath = targetStateLockPath(stateDir, "target");
        auto secondFd = open(
            lockPath.toStringz,
            O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
        );
        assert(secondFd >= 0);
        scope(exit)
            if (secondFd >= 0)
                close(secondFd);
        ensureCloseOnExec(secondFd, "independent deployment state lock test descriptor");
        validateLockDescriptor(
            secondFd,
            "Independent deployment state lock test descriptor",
            geteuid(),
        );

        assert(flock(secondFd, LOCK_EX | LOCK_NB) != 0,
            "A separately opened descriptor bypassed the held deployment state lock.");
        first.release();
        assert(flock(secondFd, LOCK_EX | LOCK_NB) == 0,
            "A separately opened descriptor stayed blocked after lock release.");
        assert(flock(secondFd, LOCK_UN) == 0);
        close(secondFd);
        secondFd = -1;
    }
}

@("test_latest_only_state_supersedes_older_deployment")
unittest
{
    import std.file : deleteme, rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest;

    auto stateDir = deleteme ~ ".state.supersede";
    scope(exit)
    {
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto oldManifest = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-41",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 41,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system-41",
    ));
    auto newManifest = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234568",
        sequence: 42,
        desiredSystemPath: "/nix/store/1123456789abcdfghijklmnpqrsvwxyz-system-42",
    ));

    assert(recordDesiredManifest(stateDir, oldManifest));
    assert(recordDesiredManifest(stateDir, newManifest));
    assert(manifestDeploymentId(loadLatestManifest(stateDir, "app-1").get) == "deploy-42");
    assert(manifestStatePath(stateDir, "superseded", "deploy-41").exists);
}

@("test_deploy_state_sanitizes_deployment_id_paths")
unittest
{
    import std.file : deleteme, rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest;

    auto stateDir = deleteme ~ ".state.sanitize-deployment-id";
    scope(exit)
    {
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto manifest = buildManifest(ManifestBuildRequest(
        deploymentId: "../targets/owned",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system",
    ));

    assert(recordDesiredManifest(stateDir, manifest));
    assert(stateDir.buildPath("desired", ".._targets_owned.json").exists);
    assert(!stateDir.buildPath("targets", "owned.json").exists);
    assert(stateDir.buildPath("targets", "app-1.json").exists);
}

@("test_latest_only_state_rejects_stale_deployment")
unittest
{
    import std.file : deleteme, rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest;

    auto stateDir = deleteme ~ ".state.reject";
    scope(exit)
    {
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto newer = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234568",
        sequence: 42,
        desiredSystemPath: "/nix/store/1123456789abcdfghijklmnpqrsvwxyz-system-42",
    ));
    auto stale = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-41",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 41,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system-41",
    ));

    assert(recordDesiredManifest(stateDir, newer));
    auto targetBefore = targetLatestPath(stateDir, "app-1").readText;
    auto desiredBefore = manifestStatePath(stateDir, "desired", "deploy-42").readText;
    auto currentBefore = manifestStatePath(stateDir, "current", "deploy-42").readText;
    assert(!recordDesiredManifest(stateDir, stale));
    assert(targetLatestPath(stateDir, "app-1").readText == targetBefore);
    assert(manifestStatePath(stateDir, "desired", "deploy-42").readText == desiredBefore);
    assert(manifestStatePath(stateDir, "current", "deploy-42").readText == currentBefore);
    assert(manifestDeploymentId(loadLatestManifest(stateDir, "app-1").get) == "deploy-42");
    assert(!manifestStatePath(stateDir, "desired", "deploy-41").exists);
    assert(!manifestStatePath(stateDir, "current", "deploy-41").exists);
    assert(!manifestStatePath(stateDir, "superseded", "deploy-41").exists);
}

@("test_latest_only_state_rejects_same_sequence_different_deployment")
unittest
{
    import std.file : deleteme, rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest;

    auto stateDir = deleteme ~ ".state.same-sequence";
    scope(exit)
    {
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto accepted = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42-a",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 42,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system-42a",
    ));
    auto duplicateSequence = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42-b",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234568",
        sequence: 42,
        desiredSystemPath: "/nix/store/1123456789abcdfghijklmnpqrsvwxyz-system-42b",
    ));

    assert(recordDesiredManifest(stateDir, accepted));
    auto targetBefore = targetLatestPath(stateDir, "app-1").readText;
    auto desiredBefore = manifestStatePath(stateDir, "desired", "deploy-42-a").readText;
    auto currentBefore = manifestStatePath(stateDir, "current", "deploy-42-a").readText;
    assert(!recordDesiredManifest(stateDir, duplicateSequence));
    assert(targetLatestPath(stateDir, "app-1").readText == targetBefore);
    assert(manifestStatePath(stateDir, "desired", "deploy-42-a").readText == desiredBefore);
    assert(manifestStatePath(stateDir, "current", "deploy-42-a").readText == currentBefore);
    assert(manifestDeploymentId(loadLatestManifest(stateDir, "app-1").get) == "deploy-42-a");
    assert(!manifestStatePath(stateDir, "desired", "deploy-42-b").exists);
    assert(!manifestStatePath(stateDir, "current", "deploy-42-b").exists);
    assert(!manifestStatePath(stateDir, "superseded", "deploy-42-b").exists);
}

@("test_latest_only_state_same_id_is_idempotent_only_for_exact_bytes_and_advances_sequence")
unittest
{
    import std.file : deleteme, rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest;

    auto stateDir = deleteme ~ ".state.same-id";
    scope(exit)
        if (stateDir.exists)
            stateDir.rmdirRecurse;

    JSONValue manifest(ulong sequence, string revision, string hash)
    {
        return buildManifest(ManifestBuildRequest(
            deploymentId: "stable-deployment-id",
            target: "app-1",
            gitRevision: revision,
            sequence: sequence,
            desiredSystemPath: "/nix/store/" ~ hash ~ "-system",
        ));
    }

    auto sequence12 = manifest(12,
        "0123456789abcdef0123456789abcdef01234567",
        "12121212121212121212121212121212");
    auto sequence12Conflict = manifest(12,
        "1123456789abcdef0123456789abcdef01234567",
        "abababababababababababababababab");
    auto sequence13 = manifest(13,
        "2123456789abcdef0123456789abcdef01234567",
        "13131313131313131313131313131313");

    assert(recordDesiredManifest(stateDir, sequence12));
    auto exactBytes = targetLatestPath(stateDir, "app-1").readText;
    auto desiredBefore = manifestStatePath(
        stateDir, "desired", "stable-deployment-id").readText;
    auto currentBefore = manifestStatePath(
        stateDir, "current", "stable-deployment-id").readText;

    assert(recordDesiredManifest(stateDir, sequence12));
    assert(targetLatestPath(stateDir, "app-1").readText == exactBytes);
    assert(manifestStatePath(stateDir, "desired", "stable-deployment-id").readText
        == desiredBefore);
    assert(manifestStatePath(stateDir, "current", "stable-deployment-id").readText
        == currentBefore);

    assert(!recordDesiredManifest(stateDir, sequence12Conflict));
    assert(targetLatestPath(stateDir, "app-1").readText == exactBytes);
    assert(manifestStatePath(stateDir, "desired", "stable-deployment-id").readText
        == desiredBefore);
    assert(manifestStatePath(stateDir, "current", "stable-deployment-id").readText
        == currentBefore);

    assert(recordDesiredManifest(stateDir, sequence13));
    assert(manifestSequence(loadLatestManifest(stateDir, "app-1").get) == 13);
    assert(manifestDeploymentId(loadLatestManifest(stateDir, "app-1").get)
        == "stable-deployment-id");
}
