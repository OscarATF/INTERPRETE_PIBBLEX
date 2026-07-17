import os, sys, threading, queue, subprocess
import tkinter as tk
from tkinter import filedialog, scrolledtext, messagebox
from tkinter import font as tkfont
from PIL import Image, ImageTk

def ruta_recurso(nombre):
    """Ruta a un archivo empaquetado DENTRO del .exe (PyInstaller lo extrae a una carpeta temporal)."""
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, nombre)


BASE = os.path.dirname(sys.executable if getattr(sys, "frozen", False) else os.path.abspath(__file__))
ICONO = ruta_recurso("icono.ico")
COMPILADOR = os.path.join(BASE, "compilador.exe")

archivo, tam = "", 12
cola = queue.Queue()


def abrir():
    global archivo
    ruta = filedialog.askopenfilename(filetypes=[("PIBBLEX", "*.pbx")])
    if not ruta:
        return
    try:
        with open(ruta, encoding="utf-8") as f:
            texto = f.read()
    except Exception as e:
        return messagebox.showerror("Error", f"No se pudo abrir:\n{e}")
    archivo = ruta
    editor.delete("1.0", tk.END)
    editor.insert(tk.END, texto)
    actualizar_lineas()


def guardar():
    global archivo
    if not archivo:
        archivo = filedialog.asksaveasfilename(defaultextension=".pbx", filetypes=[("PIBBLEX", "*.pbx")])
        if not archivo:
            return False
    try:
        with open(archivo, "w", encoding="utf-8") as f:
            f.write(editor.get("1.0", tk.END))
        return True
    except Exception as e:
        messagebox.showerror("Error", f"No se pudo guardar:\n{e}")
        return False


def mostrar_consola(texto):
    consola.config(state="normal")
    consola.delete("1.0", tk.END)
    consola.insert(tk.END, texto)
    consola.config(state="disabled")
    consola.see(tk.END)


def compilar_en_hilo(ruta):
    try:
        with open(ruta, encoding="utf-8") as entrada:
            r = subprocess.run([COMPILADOR], stdin=entrada, capture_output=True, text=True, timeout=20)
        cola.put(r.stdout + r.stderr)
    except subprocess.TimeoutExpired:
        cola.put("El compilador tardó demasiado y fue cancelado.")
    except Exception as e:
        cola.put(f"Error al compilar:\n{e}")


def revisar_cola():
    try:
        mostrar_consola(cola.get_nowait())
        boton_run.config(state="normal", text="▶ Run")
    except queue.Empty:
        ventana.after(100, revisar_cola)


def ejecutar():
    if not guardar():
        return
    if not os.path.exists(COMPILADOR):
        return mostrar_consola(f"No se encontró compilador.exe en:\n{COMPILADOR}")
    mostrar_consola("Compilando...")
    boton_run.config(state="disabled", text="Compilando...")
    threading.Thread(target=compilar_en_hilo, args=(archivo,), daemon=True).start()
    ventana.after(100, revisar_cola)


def zoom(x):
    global tam
    if tam + x >= 6:
        tam += x
        editor.config(font=("Consolas", tam))
        consola.config(font=("Consolas", tam))
        lineas.config(font=("Consolas", tam))
        actualizar_lineas()


def actualizar_lineas(event=None):
    total = int(editor.index("end-1c").split(".")[0])
    lineas.config(state="normal")
    lineas.delete("1.0", tk.END)
    lineas.insert(tk.END, "\n".join(str(i) for i in range(1, total + 1)))
    lineas.config(state="disabled")
    lineas.yview_moveto(editor.yview()[0])


def sync_scroll(*args):
    editor.yview(*args)
    lineas.yview(*args)


def cargar_icono(tamano):
    if not os.path.exists(ICONO):
        print(f"[icono] No existe: {ICONO}")
        return None
    try:
        return ImageTk.PhotoImage(Image.open(ICONO).convert("RGBA").resize(tamano, Image.LANCZOS))
    except Exception as e:
        print(f"[icono] No se pudo leer: {e}")
        return None


def aplicar_icono_ventana(win):
    if os.path.exists(ICONO):
        try:
            win.iconbitmap(ICONO)
        except Exception as e:
            print(f"[icono] No se pudo aplicar: {e}")


def iniciar_programa():
    splash = tk.Toplevel(bg="white")
    splash.overrideredirect(True)
    w, h = 400, 450
    x = (splash.winfo_screenwidth() - w) // 2
    y = (splash.winfo_screenheight() - h) // 2
    splash.geometry(f"{w}x{h}+{x}+{y}")

    img = cargar_icono((300, 300))
    if img:
        lbl = tk.Label(splash, image=img, bg="white")
        lbl.image = img
        lbl.pack(pady=20)
    else:
        tk.Label(splash, text="🐶", font=("Arial", 100), bg="white").pack(pady=30)

    tk.Label(splash, text="PIBBLEX", font=("Arial", 25, "bold"), bg="white").pack()
    tk.Label(splash, text="Cargando...", font=("Arial", 12), bg="white").pack(pady=10)
    tk.Label(splash, text="██████░░░░", font=("Consolas", 15), fg="pink", bg="white").pack()

    splash.after(2500, lambda: abrir_editor(splash))


def abrir_editor(splash):
    splash.destroy()
    global ventana, editor, consola, boton_run

    ventana = root  # reutiliza la raíz, evita un 2do Tk() que puede causar cuelgues
    ventana.deiconify()
    ventana.title("PIBBLEX IDE")
    ventana.geometry("1000x700")
    aplicar_icono_ventana(ventana)

    barra = tk.Frame(ventana)
    barra.pack(fill="x")
    tk.Button(barra, text="📂", command=abrir).pack(side="left")
    tk.Button(barra, text="💾", command=guardar).pack(side="left")
    boton_run = tk.Button(barra, text="▶ Run", bg="green", fg="white", command=ejecutar)
    boton_run.pack(side="left")
    tk.Button(barra, text="🔍+", command=lambda: zoom(1)).pack(side="left")
    tk.Button(barra, text="🔎-", command=lambda: zoom(-1)).pack(side="left")

    panel = tk.PanedWindow(ventana, orient="vertical", sashwidth=8)
    panel.pack(fill="both", expand=True)

    frame_editor = tk.Frame(panel, bg="#1e1e1e")

    global lineas
    lineas = tk.Text(
        frame_editor, width=4, font=("Consolas", tam),
        bg="#1e1e1e", fg="#6e7681", bd=0, padx=6,
        state="disabled", takefocus=0
    )
    lineas.pack(side="left", fill="y")

    editor = scrolledtext.ScrolledText(frame_editor, font=("Consolas", tam), bg="#1e1e1e", fg="white", insertbackground="white")
    editor.pack(side="right", fill="both", expand=True)

    editor.config(yscrollcommand=lambda *a: (editor.vbar.set(*a), lineas.yview_moveto(a[0])))
    editor.bind("<KeyRelease>", actualizar_lineas)
    editor.bind("<MouseWheel>", lambda e: ventana.after(1, actualizar_lineas))
    editor.bind("<ButtonRelease>", lambda e: ventana.after(1, actualizar_lineas))

    consola = scrolledtext.ScrolledText(panel, font=("Consolas", tam), bg="black", fg="lime", state="disabled")
    panel.add(frame_editor)
    panel.add(consola)

    ventana.update()
    panel.sash_place(0, 0, ventana.winfo_height() - 220)
    actualizar_lineas()


if __name__ == "__main__":
    root = tk.Tk()
    root.withdraw()
    iniciar_programa()
    root.mainloop()
