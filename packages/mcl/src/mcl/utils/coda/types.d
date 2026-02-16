module mcl.utils.coda.types;

import std.datetime : SysTime;
import std.sumtype : SumType;

// =============================================================================
// Request/Response Value Types
// =============================================================================

struct CodaCell
{
    string column;
    string value;
}

struct RowValues
{
    CodaCell[] cells;
}

// =============================================================================
// Shared Coda API Reference Types
// =============================================================================

/// Basic resource reference (page, workspace, etc.)
struct CodaRef
{
    string id;
    string type;
    string href;
    string browserLink;
    string name;
}

/// Table resource reference (includes tableType and nested parent)
struct CodaTableRef
{
    CodaRef base;
    alias this = base;
    string tableType;
    CodaRef parent;
}

// =============================================================================
// Document Types
// =============================================================================

struct Document
{
    string browserLink;
    SysTime createdAt;
    struct DocSize
    {
        bool overApiSizeLimit;
        int pageCount;
        int tableAndViewCount;
        int totalRowCount;
    }

    DocSize docSize;
    CodaRef folder;
    string folderId;
    string href;
    struct Icon
    {
        string browserLink;
        string name;
        string type;
    }

    Icon icon;
    string id;
    string name;
    string owner;
    string ownerName;
    string type;
    SysTime updatedAt;
    CodaRef workspace;
    string workspaceId;
}

struct InitialPage
{
    string name;
    string subtitle;
    string iconName;
    string imageUrl;
    string parentPageId;
    struct PageContent
    {
        string type = "canvas";
        struct CanvasContent
        {
            string format;
            string content;
        }

        CanvasContent canvasContent;
    }

    PageContent pageContent;
}

// =============================================================================
// Table Types
// =============================================================================

struct Table
{
    string id;
    string type;
    string tableType;
    string href;
    string browserLink;
    string name;
    CodaRef parent;
    CodaTableRef parentTable;
    struct DisplayColumn
    {
        string id;
        string type;
        string href;
    }
    DisplayColumn displayColumn;
    int rowCount;
    struct Sort
    {
        string direction;
        struct Column
        {
            string id;
            string type;
            string href;
        }
        Column column;
    }
    Sort[] sorts;
    string layout;
    struct Filter
    {
        bool valid;
        bool isVolatile;
        bool hasUserFormula;
        bool hasTodayFormula;
        bool hasNowFormula;
    }
    Filter filter;
    SysTime createdAt;
    SysTime updatedAt;
}

// =============================================================================
// Column Types
// =============================================================================

struct Column
{
    string id;
    string type;
    string href;
    string name;
    bool display;
    bool calculated;
    string formula;
    string defaultValue;
    struct Format
    {
        string type;
        bool isArray;
        string label;
        string disableIf;
        string action;
    }
    Format format;
    CodaTableRef parent;
}

// =============================================================================
// Row Types
// =============================================================================

alias RowValue = SumType!(string, int, bool, string[], int[], bool[]);

struct Row
{
    string id;
    string type;
    string href;
    string name;
    int index;
    string browserLink;
    SysTime createdAt;
    SysTime updatedAt;
    RowValue[string] values;
}

// =============================================================================
// Operation Response Types
// =============================================================================

struct InsertRowsReturn
{
    string requestId;
    string[] addedRowIds;
}

struct UpdateRowReturn
{
    string requestId;
    string id;
}

struct PushButtonResponse
{
    string requestId;
    string rowId;
    string columnId;
}

struct Category
{
    string name;
}
