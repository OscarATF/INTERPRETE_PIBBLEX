r"""
visualizar.py

Lee "arbol.json" y "tabla_simbolos.json" (generados por el compilador
en C solo cuando el analisis sintactico fue correcto) y los dibuja:

  - El arbol sintactico como un diagrama de nodos conectados.
  - La tabla de simbolos como una tabla real.

Si "arbol.json" no existe, significa que el programa tuvo errores
sintacticos y el compilador nunca lo genero: no hay nada que dibujar.

Requisitos:
    pip install matplotlib

Uso:
    python visualizar.py
    (ejecutalo en la misma carpeta donde corriste el compilador,
     o pasale la carpeta como argumento: python visualizar.py C:\ruta\a\la\carpeta)
"""

import json
import os
import sys

import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# Configuracion de rutas
# ---------------------------------------------------------------------------

carpeta = sys.argv[1] if len(sys.argv) > 1 else "."
RUTA_ARBOL = os.path.join(carpeta, "arbol.json")
RUTA_TABLA = os.path.join(carpeta, "tabla_simbolos.json")
RUTA_CUADRUPLOS = os.path.join(carpeta, "cuadruplos.json")

NOMBRE_REL = [">", "<", ">=", "<=", "==", "!="]


# ---------------------------------------------------------------------------
# Construccion de un arbol "visual" (etiqueta, hijos) a partir del JSON
# crudo que exporta el compilador en C.
# ---------------------------------------------------------------------------

def aplanar(n):
    """Una cadena de N_SEQ representa una lista de sentencias encadenadas
    (por la recursividad izquierda de la gramatica). Esta funcion la
    convierte en una lista plana, en el orden real del codigo fuente."""
    if n is None:
        return []
    if n["tipo"] == "N_SEQ":
        return aplanar(n["a"]) + aplanar(n["b"])
    return [n]


def aplanar_cadena_b(n):
    """Los parametros (N_PARAM) y los argumentos (N_ARG) no se encadenan
    como N_SEQ: van enlazados directamente por el campo 'b' de cada nodo
    (ver 'encadenar()' en el compilador). Esta funcion los convierte en
    una lista plana, en orden."""
    lista = []
    while n is not None:
        lista.append(n)
        n = n["b"]
    return lista


def etiqueta_de(n):
    t = n["tipo"]
    texto = n.get("texto") or ""
    texto2 = n.get("texto2") or ""
    valor = n.get("valor", 0)
    op = n.get("op", 0)

    if t == "N_NUM":
        return f"NUM ({valor:g})"
    if t == "N_ID":
        return f"ID ({texto})"
    if t == "N_BINOP":
        return f"OP ({chr(op)})"
    if t == "N_UMINUS":
        return "UMINUS (-)"
    if t == "N_REL":
        return f"REL ({NOMBRE_REL[op]})"
    if t == "N_AND":
        return "AND (&&)"
    if t == "N_OR":
        return "OR (||)"
    if t == "N_NOT":
        return "NOT (!)"
    if t == "N_DECL_ENTERO":
        return f"DECL_ENTERO ({texto})"
    if t == "N_DECL_DECIMAL":
        return f"DECL_DECIMAL ({texto})"
    if t == "N_DECL_CADENA":
        return f'DECL_CADENA ({texto} = "{texto2}")'
    if t == "N_ASSIGN_NUM":
        return f"ASSIGN ({texto})"
    if t == "N_ASSIGN_STR":
        return f'ASSIGN_STR ({texto} = "{texto2}")'
    if t == "N_PRINT_ID":
        return f"IMPRIMIR ({texto})"
    if t == "N_PRINT_EXPR":
        return "IMPRIMIR (expr)"
    if t == "N_PRINT_STR":
        return f'IMPRIMIR ("{texto2}")'
    if t == "N_IF":
        return "SI"
    if t == "N_WHILE":
        return "MIENTRAS"
    if t == "N_FUNC_DECL":
        tipo_ret = "vacio" if op == -1 else ("entero" if op == 0 else "decimal")
        return f"FUNCION {texto} -> {tipo_ret}"
    if t == "N_PARAM":
        return f"PARAM {texto} ({'entero' if op == 0 else 'decimal'})"
    if t == "N_RETURN":
        return "RETORNAR"
    if t in ("N_CALL", "N_CALL_STMT"):
        return f"LLAMAR {texto}"
    return "(nodo)"


def construir(n):
    """Convierte un nodo crudo del JSON en (etiqueta, [hijos]), donde cada
    hijo tiene la misma forma (arbol generico, facil de dibujar)."""
    if n is None:
        return None

    t = n["tipo"]
    etiqueta = etiqueta_de(n)

    if t in ("N_BINOP", "N_REL", "N_AND", "N_OR"):
        hijos = [construir(n["a"]), construir(n["b"])]
    elif t in ("N_UMINUS", "N_NOT", "N_PRINT_EXPR"):
        hijos = [construir(n["a"])]
    elif t in ("N_DECL_ENTERO", "N_DECL_DECIMAL"):
        hijos = [construir(n["a"])] if n["a"] else []
    elif t == "N_ASSIGN_NUM":
        hijos = [construir(n["a"])]
    elif t == "N_IF":
        hijos = [
            ("COND", [construir(n["a"])]),
            ("ENTONCES", [construir(x) for x in aplanar(n["b"])]),
        ]
        if n["c"]:
            hijos.append(("SINO", [construir(x) for x in aplanar(n["c"])]))
    elif t == "N_WHILE":
        hijos = [
            ("COND", [construir(n["a"])]),
            ("CUERPO", [construir(x) for x in aplanar(n["b"])]),
        ]
    elif t == "N_FUNC_DECL":
        params = aplanar_cadena_b(n["a"]) if n["a"] else []
        hijos = []
        if params:
            hijos.append(("PARAMETROS", [construir(p) for p in params]))
        hijos.append(("CUERPO", [construir(x) for x in aplanar(n["b"])]))
    elif t == "N_RETURN":
        hijos = [construir(n["a"])] if n["a"] else []
    elif t in ("N_CALL", "N_CALL_STMT"):
        args = aplanar_cadena_b(n["a"]) if n["a"] else []
        hijos = [construir(a["a"]) for a in args]
    else:
        hijos = []

    return (etiqueta, hijos)


# ---------------------------------------------------------------------------
# Layout: calcula la posicion (x, y) de cada nodo del arbol para dibujarlo
# ---------------------------------------------------------------------------

def calcular_posiciones(nodo, profundidad, contador_x, posiciones):
    etiqueta, hijos = nodo

    if not hijos:
        x = contador_x[0]
        contador_x[0] += 1
        posiciones[id(nodo)] = (x, -profundidad)
        return x

    xs_hijos = [calcular_posiciones(h, profundidad + 1, contador_x, posiciones) for h in hijos]
    x = sum(xs_hijos) / len(xs_hijos)
    posiciones[id(nodo)] = (x, -profundidad)
    return x


def dibujar_nodo(nodo, posiciones, ax, pos_padre=None):
    etiqueta, hijos = nodo
    x, y = posiciones[id(nodo)]

    if pos_padre is not None:
        ax.plot([pos_padre[0], x], [pos_padre[1] - 0.12, y + 0.12],
                color="#9aa5b1", linewidth=1.2, zorder=1)

    ax.text(x, y, etiqueta, ha="center", va="center", fontsize=8.5,
             bbox=dict(boxstyle="round,pad=0.35", fc="#eaf2ff", ec="#3b6fb0", lw=1.1),
             zorder=2)

    for h in hijos:
        dibujar_nodo(h, posiciones, ax, (x, y))


def mostrar_arbol(arbol_visual):
    posiciones = {}
    contador_x = [0]
    calcular_posiciones(arbol_visual, 0, contador_x, posiciones)

    ancho = max(6.0, contador_x[0] * 1.3)
    xs = [p[0] for p in posiciones.values()]
    ys = [p[1] for p in posiciones.values()]
    alto = max(4.0, (max(ys) - min(ys) + 2) * 0.9)

    fig, ax = plt.subplots(figsize=(ancho, alto))
    dibujar_nodo(arbol_visual, posiciones, ax)

    ax.set_xlim(min(xs) - 1, max(xs) + 1)
    ax.set_ylim(min(ys) - 1, max(ys) + 1)
    ax.axis("off")
    ax.set_title("Arbol Sintactico (AST)", fontsize=13, fontweight="bold")

    plt.tight_layout()
    plt.savefig("arbol_sintactico.png", dpi=150)
    print("Guardado: arbol_sintactico.png")
    plt.show()


# ---------------------------------------------------------------------------
# Tabla de simbolos
# ---------------------------------------------------------------------------

def mostrar_tabla(datos):
    tabla = datos.get("tabla", [])
    errores = datos.get("errores_semanticos", 0)

    if not tabla:
        print("La tabla de simbolos esta vacia (no se declararon variables).")
        return

    filas = [[s["nombre"], s["tipo"]] for s in tabla]

    fig, ax = plt.subplots(figsize=(6, 0.7 + 0.45 * len(filas)))
    ax.axis("off")

    tbl = ax.table(cellText=filas, colLabels=["Identificador", "Tipo"],
                    loc="center", cellLoc="center")
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(11)
    tbl.scale(1, 1.6)

    titulo = "Tabla de Simbolos"
    if errores > 0:
        titulo += f"  (con {errores} error(es) semantico(s))"
    ax.set_title(titulo, fontsize=13, fontweight="bold", pad=20)

    plt.tight_layout()
    plt.savefig("tabla_simbolos.png", dpi=150)
    print("Guardado: tabla_simbolos.png")
    plt.show()


# ---------------------------------------------------------------------------
# Codigo intermedio (cuadruplos)
# ---------------------------------------------------------------------------

def linea_de_cuadruplo(c):
    """Reconstruye la forma lineal (t1 = 5 + 8) a partir de un cuadruplo,
    igual que hace el compilador en C."""
    op = c["op"]
    a1, a2, res = c["arg1"], c["arg2"], c["resultado"]

    if op == "=":
        return f"{res} = {a1}"
    if op == "print":
        return f"imprimir {a1}"
    if op == "label":
        return f"{res}:"
    if op == "goto":
        return f"goto {res}"
    if op == "iffalse":
        return f"iffalse {a1} goto {res}"
    if op in ("uminus", "!"):
        return f"{res} = {op}{a1}"
    return f"{res} = {a1} {op} {a2}"


def mostrar_cuadruplos(cuadruplos):
    if not cuadruplos:
        print("No hay codigo intermedio para mostrar.")
        return

    # --- forma lineal, impresa en consola ---
    print("\nCodigo Intermedio (forma lineal):")
    print("----------------------------")
    for c in cuadruplos:
        print(linea_de_cuadruplo(c))
    print("----------------------------")

    # --- tabla de cuadruplos, como imagen ---
    filas = [[str(i + 1), c["op"], c["arg1"], c["arg2"], c["resultado"]]
              for i, c in enumerate(cuadruplos)]

    fig, ax = plt.subplots(figsize=(9, 0.7 + 0.4 * len(filas)))
    ax.axis("off")

    tbl = ax.table(cellText=filas,
                    colLabels=["#", "Op", "Arg1", "Arg2", "Resultado"],
                    loc="center", cellLoc="center")
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(10)
    tbl.scale(1, 1.5)

    ax.set_title("Codigo Intermedio (Cuadruplos)", fontsize=13, fontweight="bold", pad=20)

    plt.tight_layout()
    plt.savefig("cuadruplos.png", dpi=150)
    print("Guardado: cuadruplos.png")
    plt.show()


# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------

def main():
    if not os.path.exists(RUTA_ARBOL):
        print("No se encontro 'arbol.json'.")
        print("Esto pasa cuando el programa tuvo errores sintacticos:")
        print("el compilador solo genera el arbol si el analisis sintactico fue correcto.")
        return

    with open(RUTA_ARBOL, encoding="utf-8") as f:
        raiz_json = json.load(f)

    hijos_raiz = [construir(x) for x in aplanar(raiz_json)]
    arbol_visual = ("PROGRAMA", hijos_raiz)
    mostrar_arbol(arbol_visual)

    if os.path.exists(RUTA_TABLA):
        with open(RUTA_TABLA, encoding="utf-8") as f:
            datos_tabla = json.load(f)
        mostrar_tabla(datos_tabla)
    else:
        print("No se encontro 'tabla_simbolos.json'.")

    if os.path.exists(RUTA_CUADRUPLOS):
        with open(RUTA_CUADRUPLOS, encoding="utf-8") as f:
            cuadruplos = json.load(f)
        mostrar_cuadruplos(cuadruplos)
    else:
        print("No se encontro 'cuadruplos.json' (no hay codigo intermedio: "
              "esto pasa si el programa tuvo errores semanticos).")


if __name__ == "__main__":
    main()
