import Foundation

extension H4Archive {
    /// The archives heroes4.exe opens (0x73bec0, expansion level 2 from 0x435c80), in its order:
    /// a resource name belongs to the first archive registering it (0x7ff930 skips names already
    /// known, 0x800180), so the expansions' and updates' copies stand before heroes4.h4r's.
    public static let gameOrder = ["new.h4r", "x2_updates.h4r", "x2_override.h4r", "storm_updates.h4r", "storm_override.h4r",
                                   "updates.h4r", "text.h4r", "music.h4r", "movies.h4r", "x2.h4r", "storm.h4r", "heroes4.h4r"]
    /// The data directory's archives merged as the game resolves names (gameOrder; missing files skipped).
    public static func gameResources(dataDirectory dir: URL) -> H4Archive? {
        let all = gameOrder.compactMap { try? H4Archive(url: dir.appendingPathComponent($0)) }
        guard let first = all.first else { return nil }
        for a in all.dropFirst() { first.supplement(with: a) }
        return first
    }
}

extension RuleTables {
    /// The hero portraits (heroes4.exe 0x989ad8, 0x138 entries, count 0x73bb20): {alignment, keyword}.
    /// A portrait id -- the map's hero record (0x72f4e0, +0x6d4), a table.heroes row's (its keyword
    /// looked up here, 0x6677bb) -- indexes this list; the image is the keyword's layer in
    /// portraits.<alignment>.<52|82> (0x73bad0: 52 below size 0x52, else 82), an alias of
    /// layers.icons.hero.<alignment>.<size>. "dead" is what a dead hero shows (0x729aa0 / 0x73bb30).
    public static let heroPortraits: [(keyword: String, alignment: String)] = [
        ("chaos", ["aidan", "ajit", "ajwar", "althea", "andria", "atella", "calistar", "charzir", "dace", "darkstorm", "devin", "Flaren", "flaym", "Gretchin", "gruezak", "gundross", "hafir", "helice", "Hoogula", "iboz", "isa", "jael", "jeddite", "kardd", "kaspar", "kineta", "lorelei", "maddox", "madmarik", "mastero", "mayweda", "mered", "nazibar", "nefafareen", "norzok", "octavia", "pythia", "rana", "ritzil", "rufus", "sephinroth", "sizz", "tacitia", "ungoliant", "valynne", "xyron", "yorpix", "yoru"]),
        ("death", ["aglion", "aislinn", "archilus", "arkenvoss", "ash", "ayden", "calh", "castrata", "charna", "damala", "docata", "draezerak", "endan", "felina", "fiona", "gargareen", "grok", "harkenraz", "hastner", "hexx", "hsine", "jarvis", "jessika", "kurtos", "lamentia", "luna", "malafar", "malustar", "masqua", "mezizto", "moander", "oddrema", "panur", "paskovich", "rab", "reeva", "sandro", "sark", "shriek", "straker", "tamika", "thessa", "vidomina", "vilexica", "winsela", "xerxon", "yxia", "zaajuu", "sleeping", "dead"]),
        ("life", ["adelaide", "araja", "archimemnon", "bakrus", "bloomberg", "caitlin", "christian", "corita", "dallas", "dalt", "dorine", "frini", "gail", "ingham", "jerwall", "julia", "karth", "kathleen", "lemmar", "leslie", "marcius", "maureen", "michael", "mierna", "mirlanda", "nanette", "nevon", "olwa", "orlain", "orrin", "oyssin", "pirvian", "proetho", "rex mundi", "rion", "sanya", "sigrid", "sir mullich", "sorsha", "tamara", "thera", "tyris", "valli", "valoryn", "verdish", "virgil", "winifred", "zambu"]),
        ("might", ["abegga", "bofmog", "bron", "colwa", "crag hack", "dogwoggle", "drenka", "hagnar", "jadne", "khorrun", "krellion", "lanya", "mick", "nef", "oroon", "ranella", "shiva", "tazar", "toadeater", "trome", "vix", "wegg", "yog", "yutena"]),
        ("nature", ["aeris", "aleta", "anium", "arebell", "avanine", "blackdog", "braebar", "brook", "callis", "coronius", "derden", "eleece", "Elleshar", "enathrae", "erensar", "farnivon", "fatrim", "gem", "gill", "gue", "gwedmyr", "ignatius", "ilia", "iscandel", "ivor", "jenova", "kaliki", "kamiana", "kyrre", "labetha", "lindette", "lowell", "melodia", "mephala", "merlith", "neska", "oris", "pyral", "regina", "ryland", "saleena", "sannah", "shyn", "theritos", "tonwen", "trinni", "vialle", "yesterfox"]),
        ("order", ["abagael", "aenain", "aine", "alem", "astral", "aycora", "brendemar", "brissa", "calyphona", "cyra", "danika", "daremyth", "davius", "fafner", "fynelda", "grindan", "grum", "grunkie", "gurvilin", "hally", "hedegraus", "iona", "jubal", "malcom", "melody", "merrox", "minasli", "mudgeon", "neela", "nobblenot", "oaryn", "olivaster", "petula", "piquedram", "qubar", "raven", "redwar", "rissa", "segwen", "sharah", "solymr", "suzieque", "teddor", "theodorus", "tina", "ufretin", "urnaka", "verno"]),
        ("chaos", ["tawni_balfour", "cyrca", "pete_girly"]),
        ("nature", ["elwin", "gramin", "lord_harke"]),
        ("order", ["emilia_nighthaven", "gavin_magnus", "tharj", "genevieve", "pherlon"]),
        ("life", ["lord_lysander", "desette", "kentaine", "worton"]),
        ("might", ["waerjak"]),
        ("death", ["suraze", "gauldoth", "kalibarr"]),
        ("chaos", ["swift"]),
        ("nature", ["snowjay"]),
        ("might", ["kel", "ferret"]),
        ("life", ["mardigo", "nathaniel", "equila", "isabeau"]),
        ("nature", ["gathran"]),
        ("order", ["sylas zanj", "paulus"]),
        ("death", ["baenefa", "norticus", "varduum"]),
        ("chaos", ["scorage", "erica fade"]),
        ("nature", ["shaera"]),
        ("order", ["bohb"]),
        ("nature", ["agraynel"]),
        ("chaos", ["kozuss"]),
        ("life", ["alita eventide"]),
        ("might", ["dogwoggle_campaign"]),
        ("chaos", ["spazz_maticus"]),
        ("death", ["baron_tarkin"]),
        ("might", ["mongo"]),
        ("nature", ["erutan_revol"]),
        ("order", ["mysterio_the_magnificent"]),
    ].flatMap { a, ks in ks.map { (keyword: $0, alignment: a) } }
    private static let portraitIds: [String: Int] = Dictionary(heroPortraits.enumerated().map { ($0.element.keyword.lowercased(), $0.offset) }, uniquingKeysWith: { a, _ in a })
    /// A keyword's portrait id (0x598c20, case-insensitive), or nil.
    public static func portraitId(_ keyword: String) -> Int? { portraitIds[keyword.lowercased()] }
}

/// Hero portrait images as the game draws them (0x73bad0): the portrait's layer in its alignment's
/// sheet, looked up in the game's archive order (the expansions' sheets add their heroes).
public final class HeroPortraits {
    let resources: H4Archive
    var sheets: [String: LayerFile] = [:]
    public init(resources: H4Archive) { self.resources = resources }

    func sheet(_ alignment: String, _ size: Int) -> LayerFile? {
        let key = "\(alignment).\(size)"
        if let s = sheets[key] { return s }
        guard let d = try? resources.payload("layers.icons.hero.\(key).h4d"), let f = try? LayerFile(data: d) else { return nil }
        sheets[key] = f
        return f
    }
    /// A portrait id's image at 52 or 82 px.
    public func image(id: Int, size: Int = 52) -> UILayer? {
        guard RuleTables.heroPortraits.indices.contains(id) else { return nil }
        let p = RuleTables.heroPortraits[id]
        let name = p.keyword.lowercased()
        return sheet(p.alignment, size < 0x52 ? 52 : 82)?.layers.first { $0.name.lowercased() == name }
    }
    /// A hero keyword's image: its portrait id's; a keyword outside the table (none in the game's
    /// data) is looked for in the given alignment's sheet.
    public func image(keyword: String, alignment: String, size: Int = 52) -> UILayer? {
        if let id = RuleTables.portraitId(keyword) { return image(id: id, size: size) }
        let name = keyword.lowercased()
        return sheet(alignment, size < 0x52 ? 52 : 82)?.layers.first { $0.name.lowercased() == name }
    }
}
