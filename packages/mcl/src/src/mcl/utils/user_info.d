module mcl.utils.user_info;

import std.typecons : Nullable, nullable;

version (Posix):

import core.sys.posix.sys.types : gid_t;
import core.sys.posix.unistd : getgid;
import core.sys.posix.grp : getgrnam;

immutable Nullable!gid_t nixbld_gid;

shared static this()
{
    nixbld_gid = getGroupId("nixbld");
}

bool isNixbld()
{
    return !nixbld_gid.isNull && getgid() == nixbld_gid.get;
}

@("isNixbld")
unittest
{
    import std.process : environment;

    if ("NIX_BUILD_TOP" !in environment)
        assert(!isNixbld());

    if (isNixbld())
    {
        assert("NIX_BUILD_TOP" in environment);
        assert(!nixbld_gid.isNull);
        assert(nixbld_gid.get == getgid());
    }
}


Nullable!gid_t getGroupId(in char[] groupName)
{
    import std.internal.cstring : tempCString;

    auto groupNameZ = tempCString(groupName);
    auto group = getgrnam(groupNameZ);

    if (group is null)
        return Nullable!gid_t();

    return nullable(group.gr_gid);
}

@("getGroupId")
unittest
{
    import std.exception : assertThrown;

    assert(getGroupId("root").get == 0);
    assert(getGroupId("nogroup").get == 65534);
    assert(getGroupId("non-existant-group-12313123123123123123123").isNull);
}
