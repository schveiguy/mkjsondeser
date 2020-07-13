import iopipe.bufpipe;
import iopipe.textpipe;
import std.io;
import iopipe.json.serialize;
import iopipe.json.parser;
import iopipe.json.dom;
import std.typecons;

alias Json = JSONValue!(string);

struct JsonPrinter 
{
    Json item;
    void output(Out)(auto ref Out outputstream, size_t indent)
    {
        import std.format;
        import std.range : put;
        with(JSONType) final switch(item.type)
        {
        case Integer:
            formattedWrite(outputstream, "%s", item.integer);
            break;
        case Floating:
            formattedWrite(outputstream, "%s", item.floating);
            break;
        case String:
            put(outputstream, '"');
            put(outputstream, item.str);
            put(outputstream, '"');
            break;
        case Null:
            put(outputstream, "null");
            break;
        case Bool:
            put(outputstream, item.boolean ? "true" : "false");
            break;
        case Array:
            {
                auto arr = item.array;
                bool first = true;
                put(outputstream, "[");
                foreach(ref j; arr)
                {
                    if(!first)
                        put(outputstream, ", ");
                    else
                        first = false;
                    JsonPrinter(j).output(outputstream, indent);
                }
                put(outputstream, "]");
                break;
            }
        case Obj:
            {
                import std.range : repeat;
                auto obj = item.object;
                if(obj.length == 0)
                    put(outputstream, "{}");
                else
                {
                    put(outputstream, "{\n");
                    bool first = true;
                    foreach(k, v; obj)
                    {
                        if(first)
                            first = false;
                        else
                            put(outputstream, ",\n");
                        put(outputstream, repeat('\t', indent + 1));
                        put(outputstream, k);
                        put(outputstream, ": ");
                        JsonPrinter(v).output(outputstream, indent + 1);
                    }
                    put(outputstream, "\n");
                    put(outputstream, repeat('\t', indent));
                    put(outputstream, "}");
                }
                break;
            }
        }
    }
    void toString(Out)(auto ref Out outputstream)
    {
        output(outputstream, 0);
    }
}

enum AggregateType : ubyte
{
    primitive,
    nullable,
    obj,
    arr,
}

struct Type
{
    AggregateType type;
    bool isOptional;
    bool isNullable;
    string primitiveTypeName;

    Type *[string] objectMembers;
    Type *arrayType;
    bool[string] invalidSymbols;

    size_t typeNum;

    string typeDeclarations;
}

void makeWildcard(Type *t)
{
    t.type = AggregateType.primitive;
    t.primitiveTypeName = "*";
    t.isNullable = false;
    t.objectMembers.clear();
    t.arrayType = null;
    t.invalidSymbols = null;
}

bool isValidSymbol(string s)
{
    import std.uni;
    if(s.length == 0) return false;
    foreach(pos, dchar d; s)
        if(pos == 0 && !(isAlpha(d) || d == '_'))
            return false;
        else if(!(isAlphaNum(d) || d == '_'))
            return false;
    return true;
}

Type *generateTypes(ref Json dom, Type *existing = null)
{
    with(JSONType) final switch(dom.type)
    {
    case Integer:
        if(existing !is null)
        {
            // verify the type is identical
            if(existing.type == AggregateType.nullable)
            {
                existing.type = AggregateType.primitive;
                existing.primitiveTypeName = "long";
            }
            else if(existing.type != AggregateType.primitive ||
               (existing.primitiveTypeName != "long" && 
               existing.primitiveTypeName != "double"))
            {
                makeWildcard(existing);
            }
            return  existing;
        }
        // no existing type
        return new Type(AggregateType.primitive, false, false, "long");
    case Floating:
        if(existing !is null)
        {
            // verify the type is identical
            if(existing.type == AggregateType.nullable)
            {
                existing.type = AggregateType.primitive;
                existing.primitiveTypeName = "double";
            }
            else if(existing.type != AggregateType.primitive ||
               (existing.primitiveTypeName != "long" && 
               existing.primitiveTypeName != "double"))
            {
                makeWildcard(existing);
            }
            else
                existing.primitiveTypeName = "double";
            return existing;
        }
        // no existing type
        return new Type(AggregateType.primitive, false, false, "double");
    case String:
        if(existing !is null)
        {
            if(existing.type == AggregateType.nullable)
            {
                existing.type = AggregateType.primitive;
                existing.primitiveTypeName = "string";
            }
            else if(existing.type != AggregateType.primitive ||
               existing.primitiveTypeName != "string")
            {
                makeWildcard(existing);
            }
            return existing;
        }
        return new Type(AggregateType.primitive, false, false, "string");
    case Null:
        if(existing !is null)
        {
            // set the isNullableFlag unless it's the wildcard type
            if(existing.type != AggregateType.primitive ||
               existing.primitiveTypeName != "*")
            {
                existing.isNullable = true;
            }
            return existing;
        }
        return new Type(AggregateType.nullable, false, true);
    case Bool:
        if(existing !is null)
        {
            if(existing.type == AggregateType.nullable)
            {
                existing.type = AggregateType.primitive;
                existing.primitiveTypeName = "bool";
            }
            else if(existing.type != AggregateType.primitive ||
               existing.primitiveTypeName != "bool")
            {
                makeWildcard(existing);
            }
            return existing;
        }
        return new Type(AggregateType.primitive, false, false, "bool");
    case Array:
        if(existing !is null)
        {
            // already an existing type, verify it's an array.
            if(existing.type != AggregateType.arr)
            {
                // something other than an array, need to switch to wildcard.
                makeWildcard(existing);
                return existing;
            }
        }
        else
            existing = new Type(AggregateType.arr, false, false);
        // descend into the array, each item must be of the same type
        foreach(ref elem; dom.array)
            existing.arrayType = generateTypes(elem, existing.arrayType);
        return existing;
    case Obj:
        if(existing !is null)
        {
            // already an existing type, verify it's an array.
            if(existing.type != AggregateType.obj)
            {
                // something other than an object, need to switch to wildcard
                // and return.
                makeWildcard(existing);
                return existing;
            }
        }
        else
            existing = new Type(AggregateType.obj, false, false);

        // run through all the members of the dom object
        {
            // keep a list of all existing members to verify optionality
            bool[string] optionalMembers;
            foreach(k; existing.objectMembers.byKey)
                optionalMembers[k] = true;

            // descend into the object, every member must be of the same type
            foreach(k, ref elem; dom.object)
            {
                if(isValidSymbol(k))
                {
                    optionalMembers.remove(k);
                    existing.objectMembers[k] = generateTypes(elem, existing.objectMembers.get(k, null));
                }
                else
                    // some invalid symbols, they will be handled by an extras
                    // member
                    existing.invalidSymbols[k] = true;
            }
            foreach(k; optionalMembers.byKey)
                existing.objectMembers[k].isOptional = true;
        }
        return existing;
    }
}

void main()
{
    // by default, deserialize everything to DOM format.
    auto tokens = File(0).refCounted.bufd.assumeText.jsonTokenizer!false;
    auto dom = tokens.deserialize!Json;

    // descend into the tree. Any array, we will union together all the types.
    // Any other type we will generate a new type with the given members.
    auto allTypes = generateTypes(dom);

    // TODO: deduplicate any objects that are only different by whether a
    // member is optional.

    size_t typeNum = 0;

    import std.stdio;
    import std.format;
    import std.range;
    void outputTypeName(Out)(auto ref Out typeDef, Type *subt)
    {
        if(subt == null)
        {
            // not known what this type is. This only happens for empty arrays
            put(typeDef, "Unknown");
            return;
        }
        if(subt.isNullable)
            put(typeDef, "Nullable!(");
        with(AggregateType) final switch(subt.type)
        {
        case primitive:
            if(subt.primitiveTypeName == "*")
                put(typeDef, "JSONValue!(string)");
            else
                put(typeDef, subt.primitiveTypeName);
            break;
        case nullable:
            // This only happens if the only value ever seen is null,
            // default to Uknonwn.
            put(typeDef, "Unknown");
            break;
        case obj:
            formattedWrite(typeDef, "Type_%s", subt.typeNum);
            break;
        case arr:
            outputTypeName(typeDef, subt.arrayType);
            put(typeDef, "[]");
        }
        if(subt.isNullable)
            // finish the nullable instantiation
            put(typeDef, ")");
    }

    Type *[string] typeIds;

    void outputTypes(Type *t)
    {
        if(t is null || t.type == AggregateType.primitive)
            return;
        if(t.type == AggregateType.obj)
        {
            foreach(subt; t.objectMembers)
                outputTypes(subt);
            import std.array : Appender;
            import std.range : put;
            import std.format : formattedWrite;
            import std.algorithm : sort;

            Appender!string typeDef;
            // now, output the type
            foreach(k; t.objectMembers.keys.sort)
            {
                auto subt = t.objectMembers[k];
                put(typeDef, "    ");
                if(subt.isOptional)
                    put(typeDef, "@optional ");
                outputTypeName(typeDef, subt);
                // todo: what if it's a keyword?
                put(typeDef, " ");
                put(typeDef, k);
                put(typeDef, ";\n");
            }

            if(t.invalidSymbols.length > 0)
            {
                put(typeDef, "    @extras JSONValue!string _extras; //");
            }
            if(auto existing = typeDef.data in typeIds)
            {
                // exact type already exists. add any extra symbols to it, and
                // also set the typenum of this type.
                t.typeNum = (*existing).typeNum;
                foreach(k; t.invalidSymbols.byKey)
                    (*existing).invalidSymbols[k] = true;
            }
            else
            {
                t.typeNum = ++typeNum;
                typeIds[typeDef.data] = t;
                t.typeDeclarations = typeDef.data;
            }
        }
        else if(t.type == AggregateType.arr)
            // recurse
            outputTypes(t.arrayType);
    }
    writeln("module jsontypes;");
    writeln("import iopipe.json.dom : JSONValue;");
    writeln("import iopipe.json.serialize : extras, optional;");
    writeln("import std.typecons : Nullable;");
    writeln("struct Unknown {}");
    outputTypes(allTypes);

    import std.algorithm : sort;
    foreach(t; typeIds.values.sort!((a, b) => a.typeNum < b.typeNum))
    {
        writefln("struct Type_%s {", t.typeNum);
        write(t.typeDeclarations);
        if(t.invalidSymbols.length > 0)
            writefln("%-(%s, %)", t.invalidSymbols.keys.sort);
        writeln("}");
    }

    // output the message type
    write("alias MessageType = ");
    outputTypeName(stdout.lockingTextWriter, allTypes);
    writeln(";");
}
