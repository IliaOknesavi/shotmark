import AppKit
import UniformTypeIdentifiers

/// Инструменты MCP. Каждая функция приложения доступна здесь.
@MainActor
enum Tools {
    static let instructions = """
    Shotmark — скриншоты и разметка на macOS. Снимок получает id; "latest" или пропуск id — последний снимок.
    Координаты для capture_area и записи — точки экрана (начало в левом верхнем углу главного монитора, как в list_windows).
    Координаты аннотаций и crop — пиксели исходного снимка (на Retina вдвое больше точек), начало слева сверху.
    Картинка в ответах уменьшается до max_size; в тексте ответа указан множитель для пересчёта в пиксели снимка.
    """

    private static let shotID: [String: Any] = ["type": "string", "description": "id снимка; по умолчанию последний"]
    private static let retImg: [String: Any] = ["type": "boolean", "description": "вернуть картинку в ответе (по умолчанию true)"]
    private static let maxSize: [String: Any] = ["type": "integer", "description": "длинная сторона картинки в ответе, по умолчанию 1568"]
    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func obj(_ props: [String: Any], _ req: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": req]
    }

    static let annSchema: [String: Any] = [
        "type": "object",
        "required": ["type", "points"],
        "properties": [
            "type": ["type": "string", "enum": Ann.types],
            "points": ["type": "array", "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                       "description": "[[x,y],...] в пикселях снимка. arrow/line/rect/ellipse/blur/pixelate: [начало, конец]; pen/marker: ломаная; text/step: [точка]; callout: [остриё, левый верх плашки]; loupe: [что увеличить, где показать]"],
            "color": ["type": "string", "description": "#RRGGBB или #RRGGBBAA, по умолчанию красный"],
            "width": ["type": "number", "description": "толщина линии в пикселях, по умолчанию 4"],
            "text": ["type": "string", "description": "для text и callout"],
            "number": ["type": "integer", "description": "для step; по умолчанию следующий номер"],
            "fill": ["type": "boolean", "description": "залить rect/ellipse"],
            "size": ["type": "number", "description": "кегль текста, радиус шага или лупы, сила размытия, размер пикселя"],
        ],
    ]

    static var list: [[String: Any]] {
        [
            ["name": "list_displays", "description": "Мониторы: номер, рамка в точках, масштаб.", "inputSchema": obj([:])],
            ["name": "list_windows", "description": "Видимые окна: id, приложение, заголовок, рамка в точках.",
             "inputSchema": obj(["app": ["type": "string", "description": "фильтр по имени приложения"]])],
            ["name": "capture_screen", "description": "Снять весь монитор (по умолчанию тот, где курсор).",
             "inputSchema": obj(["display": ["type": "integer", "description": "номер из list_displays"], "return_image": retImg, "max_size": maxSize])],
            ["name": "capture_area", "description": "Снять прямоугольник экрана в точках.",
             "inputSchema": obj(["x": num("слева"), "y": num("сверху"), "width": num("ширина"), "height": num("высота"),
                                 "return_image": retImg, "max_size": maxSize], ["x", "y", "width", "height"])],
            ["name": "capture_window", "description": "Снять окно по id или по части заголовка / имени приложения.",
             "inputSchema": obj(["window_id": ["type": "integer"], "title": ["type": "string"], "app": ["type": "string"],
                                 "return_image": retImg, "max_size": maxSize])],
            ["name": "capture_app", "description": "Снять все видимые окна приложения одним кадром.",
             "inputSchema": obj(["app": ["type": "string", "description": "имя или bundle id"], "return_image": retImg, "max_size": maxSize], ["app"])],
            ["name": "ask_user_capture", "description": "Заморозить экран и попросить человека разметить его и выделить область (как ⌘⇧4). Ждёт, пока он нажмёт «Копировать»; возвращает итоговую картинку и его аннотации.",
             "inputSchema": obj(["prompt": ["type": "string", "description": "подсказка на панели инструментов"], "max_size": maxSize])],
            ["name": "open_image", "description": "Загрузить картинку из файла как новый снимок (для разметки).",
             "inputSchema": obj(["path": ["type": "string"], "open_editor": ["type": "boolean"]], ["path"])],
            ["name": "open_editor", "description": "Открыть снимок в редакторе. wait=true — дождаться закрытия и вернуть результат.",
             "inputSchema": obj(["shot_id": shotID, "wait": ["type": "boolean"], "max_size": maxSize])],
            ["name": "annotate", "description": "Добавить аннотации на снимок (одна операция отмены на вызов).",
             "inputSchema": obj(["shot_id": shotID, "annotations": ["type": "array", "items": annSchema],
                                 "return_image": retImg, "max_size": maxSize], ["annotations"])],
            ["name": "get_annotations", "description": "Аннотации и обрезка снимка в JSON (в том числе нарисованные человеком).",
             "inputSchema": obj(["shot_id": shotID])],
            ["name": "remove_annotations", "description": "Удалить аннотации по индексам из get_annotations или все (all=true).",
             "inputSchema": obj(["shot_id": shotID, "indices": ["type": "array", "items": ["type": "integer"]], "all": ["type": "boolean"]])],
            ["name": "undo", "description": "Отменить последние изменения.", "inputSchema": obj(["shot_id": shotID, "steps": ["type": "integer"]])],
            ["name": "redo", "description": "Повторить отменённое.", "inputSchema": obj(["shot_id": shotID, "steps": ["type": "integer"]])],
            ["name": "crop", "description": "Обрезать снимок (пиксели). Без x/y/width/height — сбросить обрезку.",
             "inputSchema": obj(["shot_id": shotID, "x": num(""), "y": num(""), "width": num(""), "height": num("")])],
            ["name": "export", "description": "Сохранить снимок в файл и (или) скопировать в буфер обмена.",
             "inputSchema": obj(["shot_id": shotID, "path": ["type": "string", "description": "путь .png/.jpg; без пути — только буфер"],
                                 "clipboard": ["type": "boolean", "description": "скопировать в буфер (по умолчанию true, если нет path)"],
                                 "annotated": ["type": "boolean", "description": "с разметкой (по умолчанию true)"]])],
            ["name": "history", "description": "Список последних снимков.", "inputSchema": obj(["limit": ["type": "integer"]])],
            ["name": "get_image", "description": "Снимок как изображение (последний или по id).",
             "inputSchema": obj(["shot_id": shotID, "annotated": ["type": "boolean"], "max_size": maxSize])],
            ["name": "start_recording", "description": "Начать запись экрана в MP4: область в точках или монитор целиком.",
             "inputSchema": obj(["x": num(""), "y": num(""), "width": num(""), "height": num(""), "display": ["type": "integer"]])],
            ["name": "stop_recording", "description": "Остановить запись и вернуть путь к файлу.", "inputSchema": obj([:])],
        ]
    }

    static func call(_ name: String, _ a: [String: Any]) async throws -> [[String: Any]] {
        func d(_ k: String) -> CGFloat? { (a[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
        func i(_ k: String) -> Int? { (a[k] as? NSNumber)?.intValue }
        func b(_ k: String, _ def: Bool) -> Bool { (a[k] as? Bool) ?? def }
        func s(_ k: String) -> String? { a[k] as? String }
        func shot() throws -> Shot {
            guard let sh = Store.shared.get(s("shot_id")) else { throw ShotError("снимок \(s("shot_id") ?? "latest") не найден") }
            return sh
        }
        let maxSide = i("max_size") ?? 1568

        switch name {
        case "list_displays":
            let c = try await Capture.content()
            let rows = c.displays.enumerated().map { n, d in
                "\(n): id \(d.displayID), x \(Int(d.frame.minX)) y \(Int(d.frame.minY)) \(Int(d.frame.width))×\(Int(d.frame.height)) pt, масштаб \(Capture.scale(d.displayID))"
            }
            return [text(rows.joined(separator: "\n"))]

        case "list_windows":
            var ws = try await Capture.windows()
            if let app = s("app")?.lowercased() { ws = ws.filter { ($0.owningApplication?.applicationName.lowercased() ?? "").contains(app) } }
            let rows: [[String: Any]] = ws.map { w in
                ["id": w.windowID, "app": w.owningApplication?.applicationName ?? "", "title": w.title ?? "",
                 "x": Int(w.frame.minX), "y": Int(w.frame.minY), "width": Int(w.frame.width), "height": Int(w.frame.height)]
            }
            return [text(String(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]), encoding: .utf8)!)]

        case "capture_screen":
            return result(Store.shared.add(try await Capture.screen(index: i("display")), source: "screen"), a, maxSide)

        case "capture_area":
            guard let x = d("x"), let y = d("y"), let w = d("width"), let h = d("height") else { throw ShotError("нужны x, y, width, height") }
            return result(Store.shared.add(try await Capture.area(CGRect(x: x, y: y, width: w, height: h)), source: "area"), a, maxSide)

        case "capture_window":
            var id = i("window_id").map { CGWindowID($0) }
            if id == nil {
                let q = (s("title") ?? "").lowercased(), app = (s("app") ?? "").lowercased()
                guard !q.isEmpty || !app.isEmpty else { throw ShotError("нужен window_id, title или app") }
                // из подходящих — самое большое окно (у приложения бывают служебные полоски)
                id = try await Capture.windows().filter { w in
                    (q.isEmpty || (w.title ?? "").lowercased().contains(q)) &&
                    (app.isEmpty || (w.owningApplication?.applicationName.lowercased() ?? "").contains(app))
                }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.windowID
            }
            guard let id else { throw ShotError("окно не найдено; посмотрите list_windows") }
            return result(Store.shared.add(try await Capture.window(id), source: "window \(id)"), a, maxSide)

        case "capture_app":
            guard let app = s("app") else { throw ShotError("нужен app") }
            return result(Store.shared.add(try await Capture.app(app), source: "app \(app)"), a, maxSide)

        case "ask_user_capture":
            guard let sh = await Editor.captureInPlace(hint: s("prompt")) else { throw ShotError("человек отменил снимок") }
            return result(sh, a, maxSide, withAnnotations: true)

        case "open_image":
            guard let p = s("path") else { throw ShotError("нужен path") }
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            guard let img = loadImage(url) else { throw ShotError("не удалось прочитать \(url.path)") }
            let sh = Store.shared.add(img, source: "file \(url.path)")
            if b("open_editor", false) { Editor.show(sh) }
            return [text(describe(sh))]

        case "open_editor":
            let sh = try shot()
            let e = Editor.show(sh)
            if b("wait", false) {
                await e.waitClose()
                return result(sh, a, maxSide, withAnnotations: true)
            }
            return [text("Редактор открыт: \(sh.id)")]

        case "annotate":
            let sh = try shot()
            guard let raw = a["annotations"] as? [[String: Any]] else { throw ShotError("нужен массив annotations") }
            var anns = try raw.map(parseAnn)
            var next = sh.nextStep
            for k in anns.indices where anns[k].type == "step" && anns[k].number == nil { anns[k].number = next; next += 1 }
            sh.apply { $0.anns += anns }
            return result(sh, a, maxSide, note: "Добавлено аннотаций: \(anns.count), всего \(sh.state.anns.count).")

        case "get_annotations":
            let sh = try shot()
            let data = try JSONEncoder().encode(sh.state)
            return [text("\(describe(sh))\n\(String(data: data, encoding: .utf8)!)")]

        case "remove_annotations":
            let sh = try shot()
            let idx = Set((a["indices"] as? [NSNumber])?.map(\.intValue) ?? [])
            guard b("all", false) || !idx.isEmpty else { throw ShotError("нужны indices или all=true") }
            sh.apply { st in st.anns = b("all", false) ? [] : st.anns.enumerated().filter { !idx.contains($0.offset) }.map(\.element) }
            return [text("Осталось аннотаций: \(sh.state.anns.count)")]

        case "undo", "redo":
            let sh = try shot()
            var n = 0
            for _ in 0..<max(1, i("steps") ?? 1) where (name == "undo" ? sh.undo() : sh.redo()) { n += 1 }
            return [text("\(name): \(n) шаг(ов), аннотаций \(sh.state.anns.count)")]

        case "crop":
            let sh = try shot()
            if let x = d("x"), let y = d("y"), let w = d("width"), let h = d("height") {
                sh.apply { $0.crop = CGRect(x: x, y: y, width: w, height: h) }
            } else {
                sh.apply { $0.crop = nil }
            }
            return result(sh, a, maxSide)

        case "export":
            let sh = try shot()
            let img = Render.image(sh, annotated: b("annotated", true))
            var done: [String] = []
            if let p = s("path") {
                let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                let type: UTType = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encode(img, as: type).write(to: url)
                done.append("сохранено в \(url.path)")
            }
            if b("clipboard", s("path") == nil) { copyToClipboard(img); done.append("скопировано в буфер") }
            return [text("\(sh.id): " + done.joined(separator: ", ") + " (\(img.width)×\(img.height) px)")]

        case "history":
            let rows = Store.shared.ids().prefix(max(1, i("limit") ?? 20)).compactMap { Store.shared.get($0) }.map(describe)
            return [text(rows.isEmpty ? "Снимков нет" : rows.joined(separator: "\n"))]

        case "get_image":
            let sh = try shot()
            return result(sh, ["return_image": true, "annotated": b("annotated", true)], maxSide)

        case "start_recording":
            var r: CGRect?
            if let x = d("x"), let y = d("y"), let w = d("width"), let h = d("height") { r = CGRect(x: x, y: y, width: w, height: h) }
            let url = try await Recorder.shared.start(rect: r, display: i("display"))
            return [text("Запись идёт в \(url.path). Остановить: stop_recording.")]

        case "stop_recording":
            let url = try await Recorder.shared.stop()
            return [text("Запись сохранена: \(url.path)")]

        default:
            throw ShotError("неизвестный инструмент \(name)")
        }
    }

    // MARK: помощники

    static func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

    static func describe(_ sh: Shot) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return "\(sh.id) · \(f.string(from: sh.created)) · \(sh.source) · \(sh.base.width)×\(sh.base.height) px · аннотаций \(sh.state.anns.count)\(sh.state.crop != nil ? " · обрезан" : "") · \(Store.shared.imageURL(sh.id).path)"
    }

    static func result(_ sh: Shot, _ a: [String: Any], _ maxSide: Int, note: String? = nil, withAnnotations: Bool = false) -> [[String: Any]] {
        var out = describe(sh)
        if let note { out = note + "\n" + out }
        guard (a["return_image"] as? Bool) ?? true else { return [text(out)] }
        let full = Render.image(sh, annotated: (a["annotated"] as? Bool) ?? true)
        let img = Render.downscale(full, maxSide: maxSide)
        if img.width != full.width {
            out += String(format: "\nКартинка уменьшена: %d×%d из %d×%d px. Пиксели снимка = координаты картинки × %.4f",
                          img.width, img.height, full.width, full.height, Double(full.width) / Double(img.width))
        }
        if let c = sh.state.crop { out += "\nОбрезка начинается с (\(Int(c.minX)), \(Int(c.minY))): прибавьте это к координатам картинки." }
        if withAnnotations, let data = try? JSONEncoder().encode(sh.state.anns) {
            out += "\nАннотации: " + String(data: data, encoding: .utf8)!
        }
        var data = (try? encode(img, as: .png)) ?? Data()
        var mime = "image/png"
        if data.count > 3_000_000, let jpg = try? encode(img, as: .jpeg, quality: 0.85) { data = jpg; mime = "image/jpeg" }
        return [text(out), ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]]
    }

    static func parseAnn(_ raw: [String: Any]) throws -> Ann {
        var r = raw
        // точки можно передать и как {x, y}
        if let pts = raw["points"] as? [Any] {
            r["points"] = pts.map { p -> Any in
                if let o = p as? [String: Any], let x = o["x"], let y = o["y"] { return [x, y] }
                return p
            }
        }
        let ann: Ann
        do { ann = try JSONDecoder().decode(Ann.self, from: JSONSerialization.data(withJSONObject: r)) }
        catch { throw ShotError("аннотация не разобрана: \(raw)") }
        guard Ann.types.contains(ann.type) else { throw ShotError("неизвестный тип \(ann.type); допустимы \(Ann.types.joined(separator: ", "))") }
        guard !ann.points.isEmpty else { throw ShotError("у аннотации \(ann.type) нет points") }
        return ann
    }
}
