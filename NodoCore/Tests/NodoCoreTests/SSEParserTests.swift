import XCTest

@testable import NodoCore

final class SSEParserTests: XCTestCase {
    func testEventoSencillo() {
        var parser = SSEParser()
        let eventos = parser.consumir("data: hola\n\n")
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "hola")])
    }

    func testLineaPartidaEntreTrozos() {
        var parser = SSEParser()
        XCTAssertEqual(parser.consumir("data: ho"), [])
        let eventos = parser.consumir("la\n\n")
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "hola")])
    }

    func testVariosEventosEnUnTrozo() {
        var parser = SSEParser()
        let eventos = parser.consumir("data: uno\n\ndata: dos\n\n")
        XCTAssertEqual(eventos, [
            SSEEvent(evento: nil, datos: "uno"),
            SSEEvent(evento: nil, datos: "dos")
        ])
    }

    func testSaltoConRetornoDeCarro() {
        var parser = SSEParser()
        let eventos = parser.consumir("data: hola\r\n\r\n")
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "hola")])
    }

    /// Este caso es el que rompia: Swift considera "\r\n" un unico caracter, asi
    /// que un parser que busque "\n" en la cadena no ve los finales de linea de
    /// Windows y se queda mudo.
    func testVariosEventosConFinalesDeLineaDeWindows() {
        var parser = SSEParser()
        let eventos = parser.consumir("data: uno\r\n\r\ndata: dos\r\n\r\n")
        XCTAssertEqual(eventos.map(\.datos), ["uno", "dos"])
    }

    func testRetornoDeCarroPartidoEntreTrozos() {
        var parser = SSEParser()
        XCTAssertEqual(parser.consumir("data: hola\r"), [])
        let eventos = parser.consumir("\n\r\n")
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "hola")])
    }

    func testRetornoDeCarroSoloComoTerminador() {
        var parser = SSEParser()
        let eventos = parser.consumir("data: hola\r\r")
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "hola")])
    }

    func testAcentosYEmojiNoSeRompen() {
        var parser = SSEParser()
        let eventos = parser.consumir("data: canción 🎵\n\n")
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "canción 🎵")])
    }

    func testTrozoPartidoAMitadDeUnEmoji() {
        var parser = SSEParser()
        let bytes = Array("data: 🎵\n\n".utf8)
        // El emoji ocupa cuatro bytes: se corta justo por la mitad.
        let corte = 8

        XCTAssertEqual(parser.consumir(Data(bytes[..<corte])), [])
        let eventos = parser.consumir(Data(bytes[corte...]))
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "🎵")])
    }

    func testComentarioIgnorado() {
        var parser = SSEParser()
        let eventos = parser.consumir(": latido\n\ndata: real\n\n")
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "real")])
    }

    func testEventoConNombre() {
        var parser = SSEParser()
        let eventos = parser.consumir("event: message_stop\ndata: {}\n\n")
        XCTAssertEqual(eventos, [SSEEvent(evento: "message_stop", datos: "{}")])
    }

    func testVariasLineasDeDatosSeUnen() {
        var parser = SSEParser()
        let eventos = parser.consumir("data: uno\ndata: dos\n\n")
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "uno\ndos")])
    }

    func testDatosSinEspacioInicial() {
        var parser = SSEParser()
        let eventos = parser.consumir("data:sin-espacio\n\n")
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "sin-espacio")])
    }

    func testTerminarVuelcaLoPendiente() {
        var parser = SSEParser()
        XCTAssertEqual(parser.consumir("data: colgado"), [])
        let eventos = parser.terminar()
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "colgado")])
    }

    func testDatosVaciosSeDespachan() {
        var parser = SSEParser()
        let eventos = parser.consumir("data:\n\n")
        XCTAssertEqual(eventos, [SSEEvent(evento: nil, datos: "")])
    }

    func testEventoIlegibleNoRompeElParser() {
        var parser = SSEParser()
        let eventos = parser.consumir("data: esto no es json\n\ndata: {\"ok\":true}\n\n")
        XCTAssertEqual(eventos.count, 2)
    }
}
