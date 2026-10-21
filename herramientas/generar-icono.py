"""Genera el icono de la app (1024x1024, sin canal alfa).

iOS rechaza el icono si tiene transparencia, asi que se guarda en RGB.
Se ejecuta a mano cuando haga falta cambiar el diseno; el PNG resultante si se
versiona, porque la compilacion no lo puede regenerar sin Python.
"""

import math

from PIL import Image, ImageDraw

TAM = 1024
fondo_arriba = (12, 14, 20)
fondo_abajo = (28, 32, 44)
acento = (108, 160, 255)
acento_suave = (150, 190, 255)


def degradado_vertical(tam, arriba, abajo):
    imagen = Image.new("RGB", (tam, tam))
    dibujo = ImageDraw.Draw(imagen)
    for y in range(tam):
        t = y / (tam - 1)
        color = tuple(round(arriba[i] + (abajo[i] - arriba[i]) * t) for i in range(3))
        dibujo.line([(0, y), (tam, y)], fill=color)
    return imagen


def main():
    imagen = degradado_vertical(TAM, fondo_arriba, fondo_abajo)
    dibujo = ImageDraw.Draw(imagen)

    # Hexagono: el nodo de la red, centrado y con un poco de aire arriba.
    cx, cy = TAM / 2, TAM / 2 - 20
    radio = 300
    puntos = []
    for i in range(6):
        angulo = (math.pi / 3) * i - math.pi / 6
        puntos.append((cx + radio * math.cos(angulo),
                       cy + radio * math.sin(angulo)))

    dibujo.polygon(puntos, outline=acento, width=34)

    # Tres nodos internos conectados al centro: la idea de "un nodo que habla
    # con otros".
    interior = 130
    for i in range(3):
        angulo = (2 * math.pi / 3) * i - math.pi / 2
        x = cx + interior * math.cos(angulo)
        y = cy + interior * math.sin(angulo)
        dibujo.line([(cx, cy), (x, y)], fill=acento, width=16)
        dibujo.ellipse([x - 26, y - 26, x + 26, y + 26], fill=acento_suave)

    dibujo.ellipse([cx - 44, cy - 44, cx + 44, cy + 44], fill=acento)

    imagen.save("Nodo/Assets.xcassets/AppIcon.appiconset/AppIcon.png", "PNG")
    print("icono escrito:", imagen.size, imagen.mode)


if __name__ == "__main__":
    main()
