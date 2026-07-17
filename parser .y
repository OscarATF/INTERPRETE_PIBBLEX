%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>

int yylex();
void yyerror(const char *s);

extern int linea;

/* =====================================================
   Tabla de variables
   ===================================================== */
#define MAX_VARS 100

typedef struct {
    char nombre[64];
    int  tipo;          /* -1=no declarada, 0=entero, 1=decimal, 2=cadena */
    double valor;
    char texto[256];    /* solo para tipo cadena */
} Variable;

Variable tabla[MAX_VARS];
int num_vars = 0;

/* =====================================================
   Pila de llamadas

   Cada funcion tiene su propio ambito de variables locales
   (parametros incluidos): no ve ni modifica las variables de
   quien la llamo. Al invocar una funcion se apila un marco nuevo;
   al retornar, se desapila. Esto es lo que permite la recursion:
   cada llamada activa, aunque sea la misma funcion llamandose a
   si misma, tiene su propia copia de variables.
   ===================================================== */
#define MAX_PILA 200

typedef struct {
    Variable locales[MAX_VARS];
    int num_locales;
} Frame;

Frame pila_llamadas[MAX_PILA];
int tope_pila = -1;   /* -1 = estamos en el ambito global */

Variable *tabla_actual(void)
{
    return (tope_pila >= 0) ? pila_llamadas[tope_pila].locales : tabla;
}

int buscar(const char *nombre)
{
    Variable *t = tabla_actual();
    int n = (tope_pila >= 0) ? pila_llamadas[tope_pila].num_locales : num_vars;
    int i;
    for(i = 0; i < n; i++)
        if(strcmp(t[i].nombre, nombre) == 0)
            return i;
    return -1;
}

int crear(const char *nombre)
{
    Variable *t = tabla_actual();
    int *n = (tope_pila >= 0) ? &pila_llamadas[tope_pila].num_locales : &num_vars;
    if(*n >= MAX_VARS)
    {
        printf("Error: demasiadas variables\n");
        return 0;
    }
    strncpy(t[*n].nombre, nombre, 63);
    t[*n].tipo  = -1;
    t[*n].valor = 0;
    t[*n].texto[0] = '\0';
    return (*n)++;
}

int obtener(const char *nombre)
{
    int idx = buscar(nombre);
    return (idx == -1) ? crear(nombre) : idx;
}

/* =====================================================
   Arbol de sintaxis (AST)

   Se construye un arbol mientras se parsea el programa y
   recien se EJECUTA al terminar el parseo. Esto es lo que
   permite que "si/sino" ejecuten solo la rama correcta y
   que "mientras" pueda repetir su bloque las veces que haga
   falta (algo que un interprete de ejecucion inmediata no
   puede hacer, porque el parser nunca "vuelve atras").
   ===================================================== */

typedef enum {
    N_NUM, N_ID, N_BINOP, N_UMINUS,
    N_REL, N_AND, N_OR, N_NOT,
    N_DECL_ENTERO, N_DECL_DECIMAL, N_DECL_CADENA,
    N_ASSIGN_NUM, N_ASSIGN_STR,
    N_PRINT_ID, N_PRINT_EXPR, N_PRINT_STR,
    N_IF, N_WHILE, N_SEQ,
    N_FUNC_DECL, N_PARAM, N_RETURN, N_CALL, N_CALL_STMT, N_ARG
} TipoNodo;

typedef enum { OP_GT, OP_LT, OP_GE, OP_LE, OP_EQ, OP_NE } OpRel;

typedef struct Nodo {
    TipoNodo tipo;
    int    op;       /* '+','-','*','/','%'  o  OpRel  */
    int    nlinea;   /* linea original, para mensajes de error precisos */
    double valor;    /* literal numerico (N_NUM)                        */
    char  *texto;    /* nombre de variable (ID)                         */
    char  *texto2;   /* literal de cadena (declaracion/asignacion/print) */
    struct Nodo *a, *b, *c; /* hijos: cond/izq, then/der, else           */
} Nodo;

Nodo *raiz = NULL;

void ejecutar(Nodo *n);
double llamar_funcion(Nodo *n);

/* =====================================================
   Tabla de funciones

   Se llena durante el PARSEO (a diferencia de las variables, que
   se crean recien al ejecutar). Asi, cuando termina de parsearse
   todo el programa, cualquier funcion puede llamar a cualquier
   otra sin importar el orden en que fueron escritas.
   ===================================================== */
#define MAX_FUNCS  50
#define MAX_PARAMS 10

typedef struct {
    char  nombre[64];
    int   tipo_retorno;                    /* 0=entero, 1=decimal, -1=vacio */
    int   num_params;
    char  nombres_params[MAX_PARAMS][64];
    int   tipos_params[MAX_PARAMS];         /* 0=entero, 1=decimal */
    Nodo *cuerpo;
} FuncInfo;

FuncInfo tabla_funcs[MAX_FUNCS];
int num_funcs = 0;

int buscar_func(const char *nombre)
{
    int i;
    for(i = 0; i < num_funcs; i++)
        if(strcmp(tabla_funcs[i].nombre, nombre) == 0)
            return i;
    return -1;
}

void registrar_func(char *nombre, int tipo_retorno, Nodo *params, Nodo *cuerpo, int nlinea)
{
    FuncInfo *f;
    Nodo *p;

    if(buscar_func(nombre) != -1)
    {
        printf("Error en linea %d: la funcion '%s' ya fue declarada\n", nlinea, nombre);
        return;
    }
    if(num_funcs >= MAX_FUNCS)
    {
        printf("Error en linea %d: demasiadas funciones declaradas\n", nlinea);
        return;
    }

    f = &tabla_funcs[num_funcs];
    strncpy(f->nombre, nombre, 63);
    f->tipo_retorno = tipo_retorno;
    f->cuerpo = cuerpo;
    f->num_params = 0;

    p = params;
    while(p && f->num_params < MAX_PARAMS)
    {
        strncpy(f->nombres_params[f->num_params], p->texto, 63);
        f->tipos_params[f->num_params] = p->op;
        f->num_params++;
        p = p->b;
    }
    num_funcs++;
}

Nodo *nuevo_nodo(TipoNodo tipo)
{
    Nodo *n = calloc(1, sizeof(Nodo));
    n->tipo = tipo;
    n->nlinea = linea;
    return n;
}

Nodo *crear_num(double v)
{
    Nodo *n = nuevo_nodo(N_NUM);
    n->valor = v;
    return n;
}

Nodo *crear_idref(char *nombre)
{
    Nodo *n = nuevo_nodo(N_ID);
    n->texto = nombre;
    return n;
}

Nodo *crear_binop(int op, Nodo *a, Nodo *b)
{
    Nodo *n = nuevo_nodo(N_BINOP);
    n->op = op; n->a = a; n->b = b;
    return n;
}

Nodo *crear_uminus(Nodo *a)
{
    Nodo *n = nuevo_nodo(N_UMINUS);
    n->a = a;
    return n;
}

Nodo *crear_rel(OpRel op, Nodo *a, Nodo *b)
{
    Nodo *n = nuevo_nodo(N_REL);
    n->op = op; n->a = a; n->b = b;
    return n;
}

Nodo *crear_and(Nodo *a, Nodo *b) { Nodo *n = nuevo_nodo(N_AND); n->a = a; n->b = b; return n; }
Nodo *crear_or (Nodo *a, Nodo *b) { Nodo *n = nuevo_nodo(N_OR);  n->a = a; n->b = b; return n; }
Nodo *crear_not(Nodo *a)          { Nodo *n = nuevo_nodo(N_NOT); n->a = a; return n; }

Nodo *crear_decl(TipoNodo tipo, char *nombre, Nodo *expr)
{
    Nodo *n = nuevo_nodo(tipo);
    n->texto = nombre; n->a = expr;
    return n;
}

Nodo *crear_decl_str(char *nombre, char *lit)
{
    Nodo *n = nuevo_nodo(N_DECL_CADENA);
    n->texto = nombre; n->texto2 = lit;
    return n;
}

Nodo *crear_asig_num(char *nombre, Nodo *expr)
{
    Nodo *n = nuevo_nodo(N_ASSIGN_NUM);
    n->texto = nombre; n->a = expr;
    return n;
}

Nodo *crear_asig_str(char *nombre, char *lit)
{
    Nodo *n = nuevo_nodo(N_ASSIGN_STR);
    n->texto = nombre; n->texto2 = lit;
    return n;
}

Nodo *crear_print_id(char *nombre)   { Nodo *n = nuevo_nodo(N_PRINT_ID);   n->texto  = nombre; return n; }
Nodo *crear_print_expr(Nodo *expr)   { Nodo *n = nuevo_nodo(N_PRINT_EXPR); n->a      = expr;   return n; }
Nodo *crear_print_str(char *lit)     { Nodo *n = nuevo_nodo(N_PRINT_STR);  n->texto2 = lit;    return n; }

Nodo *crear_if(Nodo *cond, Nodo *rama_si, Nodo *rama_sino)
{
    Nodo *n = nuevo_nodo(N_IF);
    n->a = cond; n->b = rama_si; n->c = rama_sino;
    return n;
}

Nodo *crear_while(Nodo *cond, Nodo *cuerpo)
{
    Nodo *n = nuevo_nodo(N_WHILE);
    n->a = cond; n->b = cuerpo;
    return n;
}

Nodo *crear_seq(Nodo *a, Nodo *b)
{
    Nodo *n = nuevo_nodo(N_SEQ);
    n->a = a; n->b = b;
    return n;
}

/* --- Parametros, argumentos y llamadas --- */

Nodo *crear_param(int tipo, char *nombre)
{
    Nodo *n = nuevo_nodo(N_PARAM);
    n->texto = nombre;
    n->op = tipo;
    return n;
}

/* Encadena "item" al final de "lista" usando el puntero b como
   "siguiente". Se usa tanto para la lista de parametros como para
   la lista de argumentos, para conservar el orden de izquierda a
   derecha en el que aparecen. */
Nodo *encadenar(Nodo *lista, Nodo *item)
{
    Nodo *p;
    if(!lista) return item;
    p = lista;
    while(p->b) p = p->b;
    p->b = item;
    return lista;
}

Nodo *crear_arg(Nodo *expr)
{
    Nodo *n = nuevo_nodo(N_ARG);
    n->a = expr;
    return n;
}

Nodo *crear_func_decl(char *nombre, int tipo_retorno, Nodo *params, Nodo *cuerpo)
{
    Nodo *n = nuevo_nodo(N_FUNC_DECL);
    n->texto = nombre;
    n->op = tipo_retorno;
    n->a = params;
    n->b = cuerpo;
    registrar_func(nombre, tipo_retorno, params, cuerpo, n->nlinea);
    return n;
}

Nodo *crear_return(Nodo *expr)
{
    Nodo *n = nuevo_nodo(N_RETURN);
    n->a = expr;
    return n;
}

Nodo *crear_call(TipoNodo tipo, char *nombre, Nodo *args)
{
    Nodo *n = nuevo_nodo(tipo); /* N_CALL (en una expresion) o N_CALL_STMT (como sentencia) */
    n->texto = nombre;
    n->a = args;
    return n;
}

/* =====================================================
   Impresion visual del Arbol Sintactico (AST)

   Recorre el arbol construido por el parser y lo dibuja con
   indentacion, para poder mostrarlo tal como pide el esquema
   del proyecto (punto 10: Arbol Sintactico).
   ===================================================== */

const char *NOMBRE_REL[6] = { ">", "<", ">=", "<=", "==", "!=" };

void indentar(int nivel)
{
    int i;
    for(i = 0; i < nivel; i++)
        printf("  ");
}

void imprimir_arbol(Nodo *n, int nivel)
{
    if(!n) return;

    /* N_SEQ no es un nodo visible: solo encadena sentencias del mismo
       nivel, asi que no debe consumir una linea ni una indentacion
       propia (si no, se duplicaria el indentado de su hijo). */
    if(n->tipo == N_SEQ)
    {
        imprimir_arbol(n->a, nivel);
        imprimir_arbol(n->b, nivel);
        return;
    }

    indentar(nivel);

    switch(n->tipo)
    {
        case N_NUM:
            printf("NUM (%g)\n", n->valor);
            break;

        case N_ID:
            printf("ID (%s)\n", n->texto);
            break;

        case N_BINOP:
            printf("OP (%c)\n", n->op);
            imprimir_arbol(n->a, nivel + 1);
            imprimir_arbol(n->b, nivel + 1);
            break;

        case N_UMINUS:
            printf("UMINUS (-)\n");
            imprimir_arbol(n->a, nivel + 1);
            break;

        case N_REL:
            printf("REL (%s)\n", NOMBRE_REL[n->op]);
            imprimir_arbol(n->a, nivel + 1);
            imprimir_arbol(n->b, nivel + 1);
            break;

        case N_AND:
            printf("AND (&&)\n");
            imprimir_arbol(n->a, nivel + 1);
            imprimir_arbol(n->b, nivel + 1);
            break;

        case N_OR:
            printf("OR (||)\n");
            imprimir_arbol(n->a, nivel + 1);
            imprimir_arbol(n->b, nivel + 1);
            break;

        case N_NOT:
            printf("NOT (!)\n");
            imprimir_arbol(n->a, nivel + 1);
            break;

        case N_DECL_ENTERO:
            printf("DECL_ENTERO (%s)\n", n->texto);
            if(n->a) imprimir_arbol(n->a, nivel + 1);
            break;

        case N_DECL_DECIMAL:
            printf("DECL_DECIMAL (%s)\n", n->texto);
            if(n->a) imprimir_arbol(n->a, nivel + 1);
            break;

        case N_DECL_CADENA:
            printf("DECL_CADENA (%s = \"%s\")\n", n->texto, n->texto2 ? n->texto2 : "");
            break;

        case N_ASSIGN_NUM:
            printf("ASSIGN (%s)\n", n->texto);
            imprimir_arbol(n->a, nivel + 1);
            break;

        case N_ASSIGN_STR:
            printf("ASSIGN_STR (%s = \"%s\")\n", n->texto, n->texto2 ? n->texto2 : "");
            break;

        case N_PRINT_ID:
            printf("IMPRIMIR (%s)\n", n->texto);
            break;

        case N_PRINT_EXPR:
            printf("IMPRIMIR (expr)\n");
            imprimir_arbol(n->a, nivel + 1);
            break;

        case N_PRINT_STR:
            printf("IMPRIMIR (\"%s\")\n", n->texto2 ? n->texto2 : "");
            break;

        case N_IF:
            printf("SI\n");
            indentar(nivel + 1); printf("COND:\n");
            imprimir_arbol(n->a, nivel + 2);
            indentar(nivel + 1); printf("ENTONCES:\n");
            imprimir_arbol(n->b, nivel + 2);
            if(n->c)
            {
                indentar(nivel + 1); printf("SINO:\n");
                imprimir_arbol(n->c, nivel + 2);
            }
            break;

        case N_WHILE:
            printf("MIENTRAS\n");
            indentar(nivel + 1); printf("COND:\n");
            imprimir_arbol(n->a, nivel + 2);
            indentar(nivel + 1); printf("CUERPO:\n");
            imprimir_arbol(n->b, nivel + 2);
            break;

        case N_FUNC_DECL:
        {
            Nodo *p = n->a;
            printf("FUNCION %s -> %s\n", n->texto,
                   n->op == -1 ? "vacio" : (n->op == 0 ? "entero" : "decimal"));
            while(p)
            {
                indentar(nivel + 1);
                printf("PARAM %s (%s)\n", p->texto, p->op == 0 ? "entero" : "decimal");
                p = p->b;
            }
            indentar(nivel + 1); printf("CUERPO:\n");
            imprimir_arbol(n->b, nivel + 2);
            break;
        }

        case N_RETURN:
            printf("RETORNAR\n");
            if(n->a) imprimir_arbol(n->a, nivel + 1);
            break;

        case N_CALL:
        case N_CALL_STMT:
        {
            Nodo *p = n->a;
            printf("LLAMAR %s(\n", n->texto);
            while(p) { imprimir_arbol(p->a, nivel + 1); p = p->b; }
            indentar(nivel); printf(")\n");
            break;
        }

        default:
            printf("(nodo desconocido)\n");
            break;
    }
}

/* =====================================================
   Exportacion del AST a JSON (para visualizarlo en Python)

   Escribe el arbol completo tal cual quedo construido, sin
   interpretar nada: cada nodo se guarda con su tipo, su linea,
   su operador, su valor, sus textos y sus hasta 3 hijos (a,b,c).
   Python se encarga de darle formato/dibujo.

   Solo se llama a esta funcion cuando el analisis sintactico
   fue correcto (ver main), asi que si no existe el archivo
   arbol.json, significa que hubo un error sintactico.
   ===================================================== */

const char *NOMBRE_TIPO_NODO[] = {
    "N_NUM", "N_ID", "N_BINOP", "N_UMINUS",
    "N_REL", "N_AND", "N_OR", "N_NOT",
    "N_DECL_ENTERO", "N_DECL_DECIMAL", "N_DECL_CADENA",
    "N_ASSIGN_NUM", "N_ASSIGN_STR",
    "N_PRINT_ID", "N_PRINT_EXPR", "N_PRINT_STR",
    "N_IF", "N_WHILE", "N_SEQ",
    "N_FUNC_DECL", "N_PARAM", "N_RETURN", "N_CALL", "N_CALL_STMT", "N_ARG"
};

void exportar_json_string(FILE *f, const char *s)
{
    fputc('"', f);
    if(s)
    {
        while(*s)
        {
            if(*s == '"' || *s == '\\') fputc('\\', f);
            if(*s == '\n') { fputs("\\n", f); s++; continue; }
            fputc(*s, f);
            s++;
        }
    }
    fputc('"', f);
}

void exportar_nodo_json(FILE *f, Nodo *n)
{
    if(!n) { fprintf(f, "null"); return; }

    fprintf(f, "{");
    fprintf(f, "\"tipo\":\"%s\",",  NOMBRE_TIPO_NODO[n->tipo]);
    fprintf(f, "\"linea\":%d,",    n->nlinea);
    fprintf(f, "\"op\":%d,",       n->op);
    fprintf(f, "\"valor\":%g,",    n->valor);
    fprintf(f, "\"texto\":");      exportar_json_string(f, n->texto);  fprintf(f, ",");
    fprintf(f, "\"texto2\":");     exportar_json_string(f, n->texto2); fprintf(f, ",");
    fprintf(f, "\"a\":"); exportar_nodo_json(f, n->a); fprintf(f, ",");
    fprintf(f, "\"b\":"); exportar_nodo_json(f, n->b); fprintf(f, ",");
    fprintf(f, "\"c\":"); exportar_nodo_json(f, n->c);
    fprintf(f, "}");
}

void exportar_arbol_json(Nodo *raiz, const char *ruta)
{
    FILE *f = fopen(ruta, "w");
    if(!f)
    {
        printf("Advertencia: no se pudo escribir %s\n", ruta);
        return;
    }
    exportar_nodo_json(f, raiz);
    fclose(f);
}

/* =====================================================
   Analizador Semantico (fase independiente)

   Recorre el AST ANTES de ejecutar nada. Construye su propia
   tabla de simbolos (tipos declarados, no valores) y reporta
   errores/advertencias semanticas: variables no declaradas,
   incompatibilidad de tipos, cambios de tipo por redeclaracion.

   Recorre AMBAS ramas de "si/sino" y el cuerpo de "mientras" al
   menos una vez, porque el chequeo de tipos debe cubrir todos los
   caminos posibles del programa, no solo el que se ejecutaria en
   tiempo de corrida.
   ===================================================== */

typedef struct {
    char nombre[64];
    int  tipo;   /* 0=entero, 1=decimal, 2=cadena */
} SimboloSem;

SimboloSem tabla_sem[MAX_VARS];
int num_vars_sem = 0;
int errores_semanticos = 0;

/* Contexto de la funcion que se esta verificando en este momento:
   -2 = no estamos dentro de ninguna funcion (ambito global) */
int tipo_retorno_actual = -2;
int retorno_encontrado  = 0;

const char *NOMBRE_TIPO[3] = { "entero", "decimal", "cadena" };

int buscar_sem(const char *nombre)
{
    int i;
    for(i = 0; i < num_vars_sem; i++)
        if(strcmp(tabla_sem[i].nombre, nombre) == 0)
            return i;
    return -1;
}

int declarar_sem(const char *nombre, int tipo, int nlinea)
{
    int idx = buscar_sem(nombre);
    if(idx == -1)
    {
        if(num_vars_sem >= MAX_VARS)
        {
            printf("Error semantico en linea %d: demasiadas variables\n", nlinea);
            errores_semanticos++;
            return -1;
        }
        strncpy(tabla_sem[num_vars_sem].nombre, nombre, 63);
        tabla_sem[num_vars_sem].tipo = tipo;
        idx = num_vars_sem++;
    }
    else if(tabla_sem[idx].tipo != tipo)
    {
        printf("Advertencia semantica en linea %d: '%s' era %s, ahora es %s\n",
               nlinea, nombre, NOMBRE_TIPO[tabla_sem[idx].tipo], NOMBRE_TIPO[tipo]);
        tabla_sem[idx].tipo = tipo;
    }
    return idx;
}

void verificar_llamada(Nodo *n, int idx_func);

void verificar_expr(Nodo *n)
{
    if(!n) return;

    switch(n->tipo)
    {
        case N_NUM:
            break;

        case N_ID:
        {
            int idx = buscar_sem(n->texto);
            if(idx == -1)
            {
                printf("Error semantico en linea %d: '%s' no declarada\n", n->nlinea, n->texto);
                errores_semanticos++;
            }
            else if(tabla_sem[idx].tipo == 2)
            {
                printf("Error semantico en linea %d: Tipos incompatibles, '%s' es cadena y no se puede usar en una expresion numerica\n",
                       n->nlinea, n->texto);
                errores_semanticos++;
            }
            break;
        }

        case N_BINOP:
            verificar_expr(n->a);
            verificar_expr(n->b);
            break;

        case N_UMINUS:
            verificar_expr(n->a);
            break;

        case N_CALL:
        {
            int idx = buscar_func(n->texto);
            if(idx == -1)
            {
                printf("Error semantico en linea %d: la funcion '%s' no existe\n", n->nlinea, n->texto);
                errores_semanticos++;
                break;
            }
            if(tabla_funcs[idx].tipo_retorno == -1)
            {
                printf("Error semantico en linea %d: '%s' es vacio y no devuelve ningun valor, no se puede usar en una expresion\n",
                       n->nlinea, n->texto);
                errores_semanticos++;
            }
            verificar_llamada(n, idx);
            break;
        }

        default:
            break;
    }
}

void verificar_cond(Nodo *n)
{
    if(!n) return;

    switch(n->tipo)
    {
        case N_REL:
            verificar_expr(n->a);
            verificar_expr(n->b);
            break;
        case N_AND:
        case N_OR:
            verificar_cond(n->a);
            verificar_cond(n->b);
            break;
        case N_NOT:
            verificar_cond(n->a);
            break;
        default:
            break;
    }
}

/* Verifica que la cantidad de argumentos de una llamada coincida
   con la cantidad de parametros declarados, y valida cada
   argumento como expresion numerica */
void verificar_llamada(Nodo *n, int idx_func)
{
    int cuenta = 0;
    Nodo *p = n->a;
    while(p)
    {
        verificar_expr(p->a);
        cuenta++;
        p = p->b;
    }
    if(cuenta != tabla_funcs[idx_func].num_params)
    {
        printf("Error semantico en linea %d: '%s' espera %d argumento(s) y recibio %d\n",
               n->nlinea, n->texto, tabla_funcs[idx_func].num_params, cuenta);
        errores_semanticos++;
    }
}

void verificar_semantica(Nodo *n)
{
    if(!n) return;

    switch(n->tipo)
    {
        case N_SEQ:
            verificar_semantica(n->a);
            verificar_semantica(n->b);
            break;

        case N_DECL_ENTERO:
            if(n->a) verificar_expr(n->a);
            declarar_sem(n->texto, 0, n->nlinea);
            break;

        case N_DECL_DECIMAL:
            if(n->a) verificar_expr(n->a);
            declarar_sem(n->texto, 1, n->nlinea);
            break;

        case N_DECL_CADENA:
            declarar_sem(n->texto, 2, n->nlinea);
            break;

        case N_ASSIGN_NUM:
        {
            int idx = buscar_sem(n->texto);
            verificar_expr(n->a);
            if(idx == -1)
            {
                printf("Error semantico en linea %d: '%s' no declarada, usa 'entero', 'decimal' o 'cadena'\n", n->nlinea, n->texto);
                errores_semanticos++;
            }
            else if(tabla_sem[idx].tipo == 2)
            {
                printf("Error semantico en linea %d: Tipos incompatibles, '%s' es cadena y no se le puede asignar un numero\n",
                       n->nlinea, n->texto);
                errores_semanticos++;
            }
            break;
        }

        case N_ASSIGN_STR:
        {
            int idx = buscar_sem(n->texto);
            if(idx == -1)
            {
                printf("Error semantico en linea %d: '%s' no declarada, usa 'cadena'\n", n->nlinea, n->texto);
                errores_semanticos++;
            }
            else if(tabla_sem[idx].tipo != 2)
            {
                printf("Error semantico en linea %d: Tipos incompatibles, '%s' no es cadena\n", n->nlinea, n->texto);
                errores_semanticos++;
            }
            break;
        }

        case N_PRINT_ID:
        {
            int idx = buscar_sem(n->texto);
            if(idx == -1)
            {
                printf("Error semantico en linea %d: '%s' no declarada\n", n->nlinea, n->texto);
                errores_semanticos++;
            }
            break;
        }

        case N_PRINT_EXPR:
            verificar_expr(n->a);
            break;

        case N_PRINT_STR:
            break;

        case N_IF:
            verificar_cond(n->a);
            verificar_semantica(n->b);
            verificar_semantica(n->c);
            break;

        case N_WHILE:
            verificar_cond(n->a);
            verificar_semantica(n->b);
            break;

        case N_FUNC_DECL:
        {
            /* El cuerpo de la funcion se verifica en un ambito
               propio: guardamos la tabla de simbolos "de afuera" y
               la reemplazamos por una que solo tiene los parametros,
               asi el cuerpo no puede ver variables del programa
               principal ni de otras funciones */
            SimboloSem guardado[MAX_VARS];
            int num_guardado    = num_vars_sem;
            int tipo_guardado   = tipo_retorno_actual;
            int retorno_previo  = retorno_encontrado;
            Nodo *p;

            memcpy(guardado, tabla_sem, sizeof(tabla_sem));

            num_vars_sem        = 0;
            tipo_retorno_actual = n->op;
            retorno_encontrado  = 0;

            p = n->a;
            while(p)
            {
                declarar_sem(p->texto, p->op, n->nlinea);
                p = p->b;
            }

            verificar_semantica(n->b);

            if(n->op != -1 && !retorno_encontrado)
                printf("Advertencia semantica en linea %d: la funcion '%s' deberia retornar un valor (%s) en todos sus caminos\n",
                       n->nlinea, n->texto, NOMBRE_TIPO[n->op]);

            memcpy(tabla_sem, guardado, sizeof(tabla_sem));
            num_vars_sem        = num_guardado;
            tipo_retorno_actual = tipo_guardado;
            retorno_encontrado  = retorno_previo;
            break;
        }

        case N_RETURN:
            if(tipo_retorno_actual == -2)
            {
                printf("Error semantico en linea %d: 'retornar' usado fuera de una funcion\n", n->nlinea);
                errores_semanticos++;
            }
            else if(tipo_retorno_actual == -1 && n->a)
            {
                printf("Error semantico en linea %d: la funcion es vacio, 'retornar' no debe llevar un valor\n", n->nlinea);
                errores_semanticos++;
            }
            else if(tipo_retorno_actual != -1 && !n->a)
            {
                printf("Error semantico en linea %d: la funcion debe retornar un valor (%s)\n",
                       n->nlinea, NOMBRE_TIPO[tipo_retorno_actual]);
                errores_semanticos++;
            }
            else
            {
                if(n->a) verificar_expr(n->a);
                retorno_encontrado = 1;
            }
            break;

        case N_CALL_STMT:
        {
            int idx = buscar_func(n->texto);
            if(idx == -1)
            {
                printf("Error semantico en linea %d: la funcion '%s' no existe\n", n->nlinea, n->texto);
                errores_semanticos++;
                break;
            }
            verificar_llamada(n, idx);
            break;
        }

        default:
            break;
    }
}

void mostrar_tabla_simbolos(void)
{
    int i;
    printf("%-20s %-10s\n", "Identificador", "Tipo");
    printf("---------------------------------\n");
    for(i = 0; i < num_vars_sem; i++)
        printf("%-20s %-10s\n", tabla_sem[i].nombre, NOMBRE_TIPO[tabla_sem[i].tipo]);
}

void exportar_tabla_json(const char *ruta)
{
    int i;
    FILE *f = fopen(ruta, "w");
    if(!f)
    {
        printf("Advertencia: no se pudo escribir %s\n", ruta);
        return;
    }

    fprintf(f, "{\"tabla\":[");
    for(i = 0; i < num_vars_sem; i++)
    {
        if(i) fprintf(f, ",");
        fprintf(f, "{\"nombre\":");
        exportar_json_string(f, tabla_sem[i].nombre);
        fprintf(f, ",\"tipo\":\"%s\"}", NOMBRE_TIPO[tabla_sem[i].tipo]);
    }
    fprintf(f, "],\"errores_semanticos\":%d}", errores_semanticos);
    fclose(f);
}

/* =====================================================
   Generador de Codigo Intermedio (cuadruplos)

   Recorre el AST y genera codigo de tres direcciones, exactamente
   como pide el punto 14 del esquema del proyecto: variables
   temporales (t1, t2, t3...) para resultados intermedios, y
   etiquetas (L1, L2...) para saltos en "si/sino" y "mientras".

   Solo se llama si el programa ya paso el analizador semantico
   sin errores (ver main): no tiene sentido generar codigo para
   un programa con errores de tipos.
   ===================================================== */

#define MAX_CUAD 2000

typedef struct {
    char op[12];
    char arg1[64];
    char arg2[64];
    char resultado[64];
} Cuadruplo;

Cuadruplo cuadruplos[MAX_CUAD];
int num_cuad = 0;
int num_temp = 0;
int num_etq  = 0;

char *nuevo_temp(void)
{
    char *s = malloc(16);
    snprintf(s, 16, "t%d", ++num_temp);
    return s;
}

char *nueva_etiqueta(void)
{
    char *s = malloc(16);
    snprintf(s, 16, "L%d", ++num_etq);
    return s;
}

void emitir(const char *op, const char *a1, const char *a2, const char *res)
{
    if(num_cuad >= MAX_CUAD) return;
    strncpy(cuadruplos[num_cuad].op,        op  ? op  : "", 11);
    strncpy(cuadruplos[num_cuad].arg1,      a1  ? a1  : "", 63);
    strncpy(cuadruplos[num_cuad].arg2,      a2  ? a2  : "", 63);
    strncpy(cuadruplos[num_cuad].resultado, res ? res : "", 63);
    num_cuad++;
}

/* Genera codigo para una expresion numerica y devuelve el nombre
   de la variable/temporal/literal que contiene su resultado */
char *generar_expr(Nodo *n)
{
    if(!n) return strdup("");

    switch(n->tipo)
    {
        case N_NUM:
        {
            char *s = malloc(32);
            if(n->valor == (long)n->valor)
                snprintf(s, 32, "%ld", (long)n->valor);
            else
                snprintf(s, 32, "%g", n->valor);
            return s;
        }

        case N_ID:
            return strdup(n->texto ? n->texto : "");

        case N_BINOP:
        {
            char *izq = generar_expr(n->a);
            char *der = generar_expr(n->b);
            char *t   = nuevo_temp();
            char opstr[2] = { (char)n->op, '\0' };
            emitir(opstr, izq, der, t);
            return t;
        }

        case N_UMINUS:
        {
            char *a = generar_expr(n->a);
            char *t = nuevo_temp();
            emitir("uminus", a, "", t);
            return t;
        }

        case N_CALL:
        {
            Nodo *p = n->a;
            char *t;
            while(p)
            {
                char *arg = generar_expr(p->a);
                emitir("arg", arg, "", "");
                p = p->b;
            }
            t = nuevo_temp();
            emitir("call", n->texto, "", t);
            return t;
        }

        default:
            return strdup("");
    }
}

/* Genera codigo para una condicion (relacional/logica) y devuelve
   el temporal que queda con 0 (falso) o 1 (verdadero) */
char *generar_cond(Nodo *n)
{
    if(!n) return strdup("");

    switch(n->tipo)
    {
        case N_REL:
        {
            char *izq = generar_expr(n->a);
            char *der = generar_expr(n->b);
            char *t   = nuevo_temp();
            emitir(NOMBRE_REL[n->op], izq, der, t);
            return t;
        }

        case N_AND:
        {
            char *a = generar_cond(n->a);
            char *b = generar_cond(n->b);
            char *t = nuevo_temp();
            emitir("&&", a, b, t);
            return t;
        }

        case N_OR:
        {
            char *a = generar_cond(n->a);
            char *b = generar_cond(n->b);
            char *t = nuevo_temp();
            emitir("||", a, b, t);
            return t;
        }

        case N_NOT:
        {
            char *a = generar_cond(n->a);
            char *t = nuevo_temp();
            emitir("!", a, "", t);
            return t;
        }

        default:
            return strdup("");
    }
}

void generar_codigo(Nodo *n)
{
    if(!n) return;

    switch(n->tipo)
    {
        case N_SEQ:
            generar_codigo(n->a);
            generar_codigo(n->b);
            break;

        case N_DECL_ENTERO:
        case N_DECL_DECIMAL:
            if(n->a)
            {
                char *t = generar_expr(n->a);
                emitir("=", t, "", n->texto);
            }
            break;

        case N_DECL_CADENA:
        {
            char lit[300];
            snprintf(lit, sizeof(lit), "\"%s\"", n->texto2 ? n->texto2 : "");
            emitir("=", lit, "", n->texto);
            break;
        }

        case N_ASSIGN_NUM:
        {
            char *t = generar_expr(n->a);
            emitir("=", t, "", n->texto);
            break;
        }

        case N_ASSIGN_STR:
        {
            char lit[300];
            snprintf(lit, sizeof(lit), "\"%s\"", n->texto2 ? n->texto2 : "");
            emitir("=", lit, "", n->texto);
            break;
        }

        case N_PRINT_ID:
            emitir("print", n->texto, "", "");
            break;

        case N_PRINT_EXPR:
        {
            char *t = generar_expr(n->a);
            emitir("print", t, "", "");
            break;
        }

        case N_PRINT_STR:
        {
            char lit[300];
            snprintf(lit, sizeof(lit), "\"%s\"", n->texto2 ? n->texto2 : "");
            emitir("print", lit, "", "");
            break;
        }

        case N_IF:
        {
            char *cond_t   = generar_cond(n->a);
            char *etq_else = nueva_etiqueta();

            emitir("iffalse", cond_t, "", etq_else);
            generar_codigo(n->b);

            if(n->c)
            {
                char *etq_fin = nueva_etiqueta();
                emitir("goto", "", "", etq_fin);
                emitir("label", "", "", etq_else);
                generar_codigo(n->c);
                emitir("label", "", "", etq_fin);
            }
            else
            {
                emitir("label", "", "", etq_else);
            }
            break;
        }

        case N_WHILE:
        {
            char *etq_inicio = nueva_etiqueta();
            char *etq_fin    = nueva_etiqueta();

            emitir("label", "", "", etq_inicio);
            char *cond_t = generar_cond(n->a);
            emitir("iffalse", cond_t, "", etq_fin);
            generar_codigo(n->b);
            emitir("goto", "", "", etq_inicio);
            emitir("label", "", "", etq_fin);
            break;
        }

        case N_FUNC_DECL:
        {
            char etiqueta[80];
            Nodo *p = n->a;
            snprintf(etiqueta, sizeof(etiqueta), "FUNC_%s", n->texto);
            emitir("func", "", "", etiqueta);
            while(p) { emitir("param", p->texto, "", ""); p = p->b; }
            generar_codigo(n->b);
            emitir("endfunc", "", "", etiqueta);
            break;
        }

        case N_RETURN:
            if(n->a)
            {
                char *t = generar_expr(n->a);
                emitir("return", t, "", "");
            }
            else
                emitir("return", "", "", "");
            break;

        case N_CALL_STMT:
        {
            Nodo *p = n->a;
            while(p)
            {
                char *arg = generar_expr(p->a);
                emitir("arg", arg, "", "");
                p = p->b;
            }
            emitir("call", n->texto, "", "");
            break;
        }

        default:
            break;
    }
}

/* Muestra el codigo de tres direcciones en forma "lineal", tal
   como lo pide el ejemplo del esquema:  t1=5  t2=8  t3=t1+t2  A=t3 */
void mostrar_codigo_lineal(void)
{
    int i;
    for(i = 0; i < num_cuad; i++)
    {
        Cuadruplo *c = &cuadruplos[i];

        if(strcmp(c->op, "=") == 0)
            printf("%s = %s\n", c->resultado, c->arg1);
        else if(strcmp(c->op, "print") == 0)
            printf("imprimir %s\n", c->arg1);
        else if(strcmp(c->op, "label") == 0)
            printf("%s:\n", c->resultado);
        else if(strcmp(c->op, "goto") == 0)
            printf("goto %s\n", c->resultado);
        else if(strcmp(c->op, "iffalse") == 0)
            printf("iffalse %s goto %s\n", c->arg1, c->resultado);
        else if(strcmp(c->op, "uminus") == 0 || strcmp(c->op, "!") == 0)
            printf("%s = %s%s\n", c->resultado, c->op, c->arg1);
        else
            printf("%s = %s %s %s\n", c->resultado, c->arg1, c->op, c->arg2);
    }
}

/* Muestra el codigo intermedio como tabla de cuadruplos: Op, Arg1,
   Arg2, Resultado (formato alternativo que tambien pide el punto
   14 del esquema) */
void mostrar_cuadruplos(void)
{
    int i;
    printf("%-4s %-10s %-12s %-12s %-12s\n", "#", "Op", "Arg1", "Arg2", "Resultado");
    printf("------------------------------------------------------------\n");
    for(i = 0; i < num_cuad; i++)
        printf("%-4d %-10s %-12s %-12s %-12s\n",
               i + 1, cuadruplos[i].op, cuadruplos[i].arg1,
               cuadruplos[i].arg2, cuadruplos[i].resultado);
}

void exportar_cuadruplos_json(const char *ruta)
{
    int i;
    FILE *f = fopen(ruta, "w");
    if(!f)
    {
        printf("Advertencia: no se pudo escribir %s\n", ruta);
        return;
    }

    fprintf(f, "[");
    for(i = 0; i < num_cuad; i++)
    {
        if(i) fprintf(f, ",");
        fprintf(f, "{\"op\":");        exportar_json_string(f, cuadruplos[i].op);        fprintf(f, ",");
        fprintf(f, "\"arg1\":");       exportar_json_string(f, cuadruplos[i].arg1);       fprintf(f, ",");
        fprintf(f, "\"arg2\":");       exportar_json_string(f, cuadruplos[i].arg2);       fprintf(f, ",");
        fprintf(f, "\"resultado\":");  exportar_json_string(f, cuadruplos[i].resultado);
        fprintf(f, "}");
    }
    fprintf(f, "]");
    fclose(f);
}

/* =====================================================
   Optimizacion de Codigo  (punto 15 del esquema)

   Trabaja sobre los cuadruplos ya generados (cuadruplos[]) y
   produce una segunda version optimizada (cuadruplos_opt[]),
   aplicando las 4 tecnicas que pide el esquema:

     - Plegado de constantes    (x = 5+8         ->  x = 13)
     - Propagacion de constantes(t1=5; t2=t1+3   ->  t1=5; t2=5+3)
     - Simplificacion algebraica(x+0, x*1, x*0, x-0, x/1 ...)
     - Eliminacion de codigo muerto (temporales que quedan
       calculados pero nunca se vuelven a usar)

   El original (cuadruplos[]) se conserva intacto para poder
   mostrar el "Antes" / "Despues" tal como pide el ejemplo del
   esquema (x=5+8  ->  x=13).
   ===================================================== */

/* ¿"s" es un temporal generado por el compilador (t1, t2, ...)? */
int es_temporal(const char *s)
{
    int i;
    if(!s || s[0] != 't' || !s[1]) return 0;
    for(i = 1; s[i]; i++)
        if(!isdigit((unsigned char)s[i])) return 0;
    return 1;
}

/* ¿"s" es un literal numerico (entero o decimal, con signo)? */
int es_numero_literal(const char *s)
{
    int i = 0, tiene_digito = 0;
    if(!s || !s[0]) return 0;
    if(s[0] == '-') i = 1;
    for(; s[i]; i++)
    {
        if(isdigit((unsigned char)s[i])) tiene_digito = 1;
        else if(s[i] != '.') return 0;
    }
    return tiene_digito;
}

void formatear_numero(double v, char *out, size_t n)
{
    if(v == (long)v)
        snprintf(out, n, "%ld", (long)v);
    else
        snprintf(out, n, "%g", v);
}

/* ---- Tabla de constantes conocidas en tiempo de compilacion ---- */
#define MAX_CONST_OPT 500

typedef struct {
    char nombre[64];
    char valor[32];
    int  activo;
} ConstOpt;

ConstOpt tabla_const_opt[MAX_CONST_OPT];
int num_const_opt = 0;

const char *opt_const_get(const char *nombre)
{
    int i;
    if(!nombre || !nombre[0] || es_numero_literal(nombre)) return NULL;
    for(i = 0; i < num_const_opt; i++)
        if(tabla_const_opt[i].activo && strcmp(tabla_const_opt[i].nombre, nombre) == 0)
            return tabla_const_opt[i].valor;
    return NULL;
}

void opt_const_set(const char *nombre, const char *valor)
{
    int i;
    if(!nombre || !nombre[0]) return;
    for(i = 0; i < num_const_opt; i++)
        if(strcmp(tabla_const_opt[i].nombre, nombre) == 0)
        {
            strncpy(tabla_const_opt[i].valor, valor, 31);
            tabla_const_opt[i].activo = 1;
            return;
        }
    if(num_const_opt < MAX_CONST_OPT)
    {
        strncpy(tabla_const_opt[num_const_opt].nombre, nombre, 63);
        strncpy(tabla_const_opt[num_const_opt].valor, valor, 31);
        tabla_const_opt[num_const_opt].activo = 1;
        num_const_opt++;
    }
}

void opt_const_clear(const char *nombre)
{
    int i;
    for(i = 0; i < num_const_opt; i++)
        if(strcmp(tabla_const_opt[i].nombre, nombre) == 0)
        {
            tabla_const_opt[i].activo = 0;
            return;
        }
}

/* En un salto/etiqueta/llamada ya no podemos garantizar que una
   variable siga valiendo lo mismo (por ejemplo, dentro de un bucle
   "mientras"), asi que se olvida todo lo que se sabia hasta ahi */
void opt_const_clear_todo(void)
{
    int i;
    for(i = 0; i < num_const_opt; i++)
        tabla_const_opt[i].activo = 0;
}

/* ---- Cuadruplos optimizados + contadores para el reporte ---- */
Cuadruplo cuadruplos_opt[MAX_CUAD];
int num_cuad_opt = 0;

int contador_plegado      = 0;  /* plegado de constantes       */
int contador_propagado    = 0;  /* propagacion de constantes   */
int contador_simplificado = 0;  /* simplificacion algebraica   */
int contador_muerto       = 0;  /* codigo muerto eliminado     */

void optimizar_codigo(void)
{
    int i, j, cambios;
    char buf1[32];

    num_cuad_opt      = 0;
    num_const_opt     = 0;
    contador_plegado      = 0;
    contador_propagado    = 0;
    contador_simplificado = 0;
    contador_muerto       = 0;

    /* --- Paso 1: propagacion + plegado + simplificacion algebraica --- */
    for(i = 0; i < num_cuad; i++)
    {
        Cuadruplo c = cuadruplos[i];
        const char *prop;

        if(strcmp(c.op, "label")   == 0 || strcmp(c.op, "func") == 0 ||
           strcmp(c.op, "endfunc") == 0 || strcmp(c.op, "call") == 0 ||
           strcmp(c.op, "param")   == 0)
        {
            opt_const_clear_todo();
        }

        /* Propagacion de constantes */
        if(c.arg1[0] && c.arg1[0] != '"' && (prop = opt_const_get(c.arg1)) != NULL)
        {
            strncpy(c.arg1, prop, 63);
            contador_propagado++;
        }
        if(c.arg2[0] && c.arg2[0] != '"' && (prop = opt_const_get(c.arg2)) != NULL)
        {
            strncpy(c.arg2, prop, 63);
            contador_propagado++;
        }

        /* Plegado de constantes */
        if((strcmp(c.op, "+") == 0 || strcmp(c.op, "-") == 0 || strcmp(c.op, "*") == 0 ||
            strcmp(c.op, "/") == 0 || strcmp(c.op, "%") == 0) &&
           es_numero_literal(c.arg1) && es_numero_literal(c.arg2))
        {
            double a = atof(c.arg1), b = atof(c.arg2), r = 0;
            int ok = 1;

            if(c.op[0] == '+')      r = a + b;
            else if(c.op[0] == '-') r = a - b;
            else if(c.op[0] == '*') r = a * b;
            else if(c.op[0] == '/') { if(b == 0) ok = 0; else r = a / b; }
            else if(c.op[0] == '%') { if((int)b == 0) ok = 0; else r = (int)a % (int)b; }

            if(ok)
            {
                formatear_numero(r, buf1, sizeof(buf1));
                strcpy(c.op, "=");
                strncpy(c.arg1, buf1, 63);
                c.arg2[0] = '\0';
                contador_plegado++;
            }
        }
        else if(strcmp(c.op, "uminus") == 0 && es_numero_literal(c.arg1))
        {
            formatear_numero(-atof(c.arg1), buf1, sizeof(buf1));
            strcpy(c.op, "=");
            strncpy(c.arg1, buf1, 63);
            contador_plegado++;
        }

        /* Simplificacion algebraica (solo si no se pudo plegar del todo) */
        if(strcmp(c.op, "+") == 0)
        {
            if(strcmp(c.arg2, "0") == 0)      { strcpy(c.op, "="); c.arg2[0] = '\0'; contador_simplificado++; }
            else if(strcmp(c.arg1, "0") == 0) { strcpy(c.op, "="); strncpy(c.arg1, c.arg2, 63); c.arg2[0] = '\0'; contador_simplificado++; }
        }
        else if(strcmp(c.op, "-") == 0 && strcmp(c.arg2, "0") == 0)
        {
            strcpy(c.op, "="); c.arg2[0] = '\0'; contador_simplificado++;
        }
        else if(strcmp(c.op, "*") == 0)
        {
            if(strcmp(c.arg1, "0") == 0 || strcmp(c.arg2, "0") == 0)
            {
                strcpy(c.op, "="); strcpy(c.arg1, "0"); c.arg2[0] = '\0'; contador_simplificado++;
            }
            else if(strcmp(c.arg2, "1") == 0) { strcpy(c.op, "="); c.arg2[0] = '\0'; contador_simplificado++; }
            else if(strcmp(c.arg1, "1") == 0) { strcpy(c.op, "="); strncpy(c.arg1, c.arg2, 63); c.arg2[0] = '\0'; contador_simplificado++; }
        }
        else if(strcmp(c.op, "/") == 0 && strcmp(c.arg2, "1") == 0)
        {
            strcpy(c.op, "="); c.arg2[0] = '\0'; contador_simplificado++;
        }

        /* Registrar lo que ahora sabemos del resultado, para que las
           instrucciones siguientes puedan aprovechar la propagacion */
        if(strcmp(c.op, "=") == 0 && c.resultado[0])
        {
            if(es_numero_literal(c.arg1)) opt_const_set(c.resultado, c.arg1);
            else                          opt_const_clear(c.resultado);
        }
        else if(c.resultado[0] && strcmp(c.op, "label") != 0)
        {
            opt_const_clear(c.resultado);
        }

        cuadruplos_opt[num_cuad_opt++] = c;
    }

    /* --- Paso 2: eliminacion de codigo muerto ---
       Un temporal calculado y nunca vuelto a usar (ni como operando,
       ni impreso, ni como condicion, ni como argumento) no aporta
       nada: se elimina. Se repite hasta el punto fijo porque borrar
       un temporal puede dejar muerto a otro que solo lo alimentaba. */
    do
    {
        cambios = 0;
        for(i = 0; i < num_cuad_opt; i++)
        {
            int usado = 0;
            Cuadruplo *c = &cuadruplos_opt[i];

            if(!es_temporal(c->resultado)) continue;
            if(strcmp(c->op, "call") == 0) continue; /* puede tener efectos secundarios */

            for(j = 0; j < num_cuad_opt; j++)
            {
                if(j == i) continue;
                if(strcmp(cuadruplos_opt[j].arg1, c->resultado) == 0 ||
                   strcmp(cuadruplos_opt[j].arg2, c->resultado) == 0)
                {
                    usado = 1;
                    break;
                }
            }

            if(!usado)
            {
                for(j = i; j < num_cuad_opt - 1; j++)
                    cuadruplos_opt[j] = cuadruplos_opt[j + 1];
                num_cuad_opt--;
                contador_muerto++;
                cambios = 1;
                i--;
            }
        }
    } while(cambios);
}

/* Igual que mostrar_codigo_lineal(), pero sobre el codigo YA
   optimizado (cuadruplos_opt) */
void mostrar_codigo_lineal_opt(void)
{
    int i;
    for(i = 0; i < num_cuad_opt; i++)
    {
        Cuadruplo *c = &cuadruplos_opt[i];

        if(strcmp(c->op, "=") == 0)
            printf("%s = %s\n", c->resultado, c->arg1);
        else if(strcmp(c->op, "print") == 0)
            printf("imprimir %s\n", c->arg1);
        else if(strcmp(c->op, "label") == 0)
            printf("%s:\n", c->resultado);
        else if(strcmp(c->op, "goto") == 0)
            printf("goto %s\n", c->resultado);
        else if(strcmp(c->op, "iffalse") == 0)
            printf("iffalse %s goto %s\n", c->arg1, c->resultado);
        else if(strcmp(c->op, "uminus") == 0 || strcmp(c->op, "!") == 0)
            printf("%s = %s%s\n", c->resultado, c->op, c->arg1);
        else
            printf("%s = %s %s %s\n", c->resultado, c->arg1, c->op, c->arg2);
    }
}

/* Igual que mostrar_cuadruplos(), pero sobre el codigo optimizado */
void mostrar_cuadruplos_opt(void)
{
    int i;
    printf("%-4s %-10s %-12s %-12s %-12s\n", "#", "Op", "Arg1", "Arg2", "Resultado");
    printf("------------------------------------------------------------\n");
    for(i = 0; i < num_cuad_opt; i++)
        printf("%-4d %-10s %-12s %-12s %-12s\n",
               i + 1, cuadruplos_opt[i].op, cuadruplos_opt[i].arg1,
               cuadruplos_opt[i].arg2, cuadruplos_opt[i].resultado);
}

void exportar_cuadruplos_opt_json(const char *ruta)
{
    int i;
    FILE *f = fopen(ruta, "w");
    if(!f)
    {
        printf("Advertencia: no se pudo escribir %s\n", ruta);
        return;
    }

    fprintf(f, "{\"cuadruplos\":[");
    for(i = 0; i < num_cuad_opt; i++)
    {
        if(i) fprintf(f, ",");
        fprintf(f, "{\"op\":");        exportar_json_string(f, cuadruplos_opt[i].op);        fprintf(f, ",");
        fprintf(f, "\"arg1\":");       exportar_json_string(f, cuadruplos_opt[i].arg1);       fprintf(f, ",");
        fprintf(f, "\"arg2\":");       exportar_json_string(f, cuadruplos_opt[i].arg2);       fprintf(f, ",");
        fprintf(f, "\"resultado\":");  exportar_json_string(f, cuadruplos_opt[i].resultado);
        fprintf(f, "}");
    }
    fprintf(f, "],");
    fprintf(f, "\"resumen\":{");
    fprintf(f, "\"plegado_constantes\":%d,",        contador_plegado);
    fprintf(f, "\"propagacion_constantes\":%d,",    contador_propagado);
    fprintf(f, "\"simplificacion_algebraica\":%d,", contador_simplificado);
    fprintf(f, "\"codigo_muerto_eliminado\":%d",    contador_muerto);
    fprintf(f, "}}");
    fclose(f);
}

/* =====================================================
   Generacion de Codigo Final  (punto 16 del esquema)

   A partir del codigo intermedio YA OPTIMIZADO (cuadruplos_opt),
   se puede generar codigo en dos formatos, tal como pide el
   esquema ("Puede generarse Codigo C++ o Codigo ensamblador
   sencillo"):

     - Codigo C++ compilable (declaraciones + sentencias)
     - Codigo ensamblador sencillo estilo MOV/ADD/SUB... (AX
       como registro acumulador, igual que el ejemplo del esquema)

   Se generan ambos, ya que el proyecto puede requerir mostrar
   cualquiera de las dos opciones ("o") segun el tipo de lenguaje
   de salida que se elija para la demostracion.
   ===================================================== */

/* Escribe la misma linea en pantalla (printf) y en el archivo de
   salida (fprintf) al mismo tiempo, para no duplicar la logica de
   generacion de codigo */
void emitir_doble(FILE *f, const char *fmt, ...)
{
    va_list args;

    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);

    va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
}

int es_operador_relacional_o_logico(const char *op)
{
    return strcmp(op, ">")  == 0 || strcmp(op, "<")  == 0 ||
           strcmp(op, ">=") == 0 || strcmp(op, "<=") == 0 ||
           strcmp(op, "==") == 0 || strcmp(op, "!=") == 0 ||
           strcmp(op, "&&") == 0 || strcmp(op, "||") == 0;
}

/* ---------------------------------------------------------------
   16.a  Codigo C++
   --------------------------------------------------------------- */
void generar_codigo_cpp(const char *ruta)
{
    int i;
    FILE *f = fopen(ruta, "w");
    if(!f)
    {
        printf("Advertencia: no se pudo escribir %s\n", ruta);
        return;
    }

    emitir_doble(f, "#include <iostream>\n#include <string>\nusing namespace std;\n\nint main()\n{\n");

    /* Declaracion de las variables del programa, con el tipo real
       que determino el analizador semantico (punto 13) */
    for(i = 0; i < num_vars_sem; i++)
    {
        const char *tipo_cpp = (tabla_sem[i].tipo == 0) ? "int"    :
                                (tabla_sem[i].tipo == 1) ? "double" : "string";
        emitir_doble(f, "    %s %s;\n", tipo_cpp, tabla_sem[i].nombre);
    }

    /* En C++ (a diferencia de C) un goto no puede saltar por encima
       de la inicializacion de una variable declarada mas adelante en
       el mismo bloque. Como el codigo intermedio usa goto/label para
       si/mientras, TODOS los temporales se predeclaran aqui arriba,
       sin etiquetas de por medio, y en el cuerpo solo se les asigna. */
    for(i = 0; i < num_cuad_opt; i++)
    {
        Cuadruplo *c = &cuadruplos_opt[i];
        if(!es_temporal(c->resultado)) continue;

        if(strcmp(c->op, "!") == 0 || es_operador_relacional_o_logico(c->op))
            emitir_doble(f, "    int %s;\n", c->resultado);
        else
            emitir_doble(f, "    double %s;\n", c->resultado);
    }

    emitir_doble(f, "\n");

    if(num_funcs > 0)
        emitir_doble(f, "    // Nota: las funciones definidas por el usuario se muestran\n"
                         "    // simplificadas como comentarios en esta version del generador.\n\n");

    for(i = 0; i < num_cuad_opt; i++)
    {
        Cuadruplo *c = &cuadruplos_opt[i];

        if(strcmp(c->op, "label") == 0)
            emitir_doble(f, "%s: ;\n", c->resultado);

        else if(strcmp(c->op, "goto") == 0)
            emitir_doble(f, "    goto %s;\n", c->resultado);

        else if(strcmp(c->op, "iffalse") == 0)
            emitir_doble(f, "    if(!(%s)) goto %s;\n", c->arg1, c->resultado);

        else if(strcmp(c->op, "print") == 0)
            emitir_doble(f, "    cout << %s << endl;\n", c->arg1);

        else if(strcmp(c->op, "=") == 0)
            emitir_doble(f, "    %s = %s;\n", c->resultado, c->arg1);

        else if(strcmp(c->op, "uminus") == 0)
            emitir_doble(f, "    %s = -%s;\n", c->resultado, c->arg1);

        else if(strcmp(c->op, "!") == 0)
            emitir_doble(f, "    %s = !%s;\n", c->resultado, c->arg1);

        else if(es_operador_relacional_o_logico(c->op))
            emitir_doble(f, "    %s = (%s %s %s);\n", c->resultado, c->arg1, c->op, c->arg2);

        else if(strcmp(c->op, "func") == 0)
            emitir_doble(f, "    // ---- inicio funcion: %s ----\n", c->resultado);

        else if(strcmp(c->op, "endfunc") == 0)
            emitir_doble(f, "    // ---- fin funcion: %s ----\n", c->resultado);

        else if(strcmp(c->op, "param") == 0)
            emitir_doble(f, "    // parametro: %s\n", c->arg1);

        else if(strcmp(c->op, "arg") == 0)
            emitir_doble(f, "    // argumento: %s\n", c->arg1);

        else if(strcmp(c->op, "call") == 0)
        {
            if(c->resultado[0])
                emitir_doble(f, "    // %s = llamada a %s(...)\n", c->resultado, c->arg1);
            else
                emitir_doble(f, "    // llamada a %s(...)\n", c->arg1);
        }

        else if(strcmp(c->op, "return") == 0)
            emitir_doble(f, "    // retornar %s\n", c->arg1[0] ? c->arg1 : "");

        else /* +, -, *, /, %  entre operandos que no se pudieron plegar */
            emitir_doble(f, "    %s = %s %s %s;\n", c->resultado, c->arg1, c->op, c->arg2);
    }

    emitir_doble(f, "\n    return 0;\n}\n");
    fclose(f);
}

/* ---------------------------------------------------------------
   16.b  Codigo ensamblador sencillo (estilo MOV/ADD/SUB..., con
   AX como registro acumulador unico, tal como el ejemplo del
   esquema: MOV AX,5 / ADD AX,8 / MOV A,AX)
   --------------------------------------------------------------- */
void generar_codigo_asm(const char *ruta)
{
    int i;
    FILE *f = fopen(ruta, "w");
    if(!f)
    {
        printf("Advertencia: no se pudo escribir %s\n", ruta);
        return;
    }

    emitir_doble(f, "; Codigo ensamblador simplificado (registro acumulador AX)\n");
    emitir_doble(f, "; generado a partir del codigo intermedio ya optimizado\n\n");

    for(i = 0; i < num_cuad_opt; i++)
    {
        Cuadruplo *c = &cuadruplos_opt[i];

        if(strcmp(c->op, "label") == 0)
            emitir_doble(f, "%s:\n", c->resultado);

        else if(strcmp(c->op, "goto") == 0)
            emitir_doble(f, "    JMP %s\n", c->resultado);

        else if(strcmp(c->op, "iffalse") == 0)
        {
            emitir_doble(f, "    MOV AX, %s\n", c->arg1);
            emitir_doble(f, "    CMP AX, 0\n");
            emitir_doble(f, "    JE %s\n", c->resultado);
        }

        else if(strcmp(c->op, "print") == 0)
        {
            emitir_doble(f, "    MOV AX, %s\n", c->arg1);
            emitir_doble(f, "    OUT AX\n");
        }

        else if(strcmp(c->op, "=") == 0)
        {
            emitir_doble(f, "    MOV AX, %s\n", c->arg1);
            emitir_doble(f, "    MOV %s, AX\n", c->resultado);
        }

        else if(strcmp(c->op, "uminus") == 0)
        {
            emitir_doble(f, "    MOV AX, %s\n", c->arg1);
            emitir_doble(f, "    NEG AX\n");
            emitir_doble(f, "    MOV %s, AX\n", c->resultado);
        }

        else if(strcmp(c->op, "!") == 0)
        {
            emitir_doble(f, "    MOV AX, %s\n", c->arg1);
            emitir_doble(f, "    NOT AX\n");
            emitir_doble(f, "    AND AX, 1\n");
            emitir_doble(f, "    MOV %s, AX\n", c->resultado);
        }

        else if(strcmp(c->op, "func") == 0)
            emitir_doble(f, "; ---- inicio funcion %s ----\n", c->resultado);

        else if(strcmp(c->op, "endfunc") == 0)
        {
            emitir_doble(f, "    RET\n");
            emitir_doble(f, "; ---- fin funcion %s ----\n", c->resultado);
        }

        else if(strcmp(c->op, "param") == 0)
            emitir_doble(f, "    ; parametro %s\n", c->arg1);

        else if(strcmp(c->op, "arg") == 0)
            emitir_doble(f, "    PUSH %s\n", c->arg1);

        else if(strcmp(c->op, "call") == 0)
        {
            emitir_doble(f, "    CALL %s\n", c->arg1);
            if(c->resultado[0])
                emitir_doble(f, "    MOV %s, AX\n", c->resultado);
        }

        else if(strcmp(c->op, "return") == 0)
        {
            if(c->arg1[0]) emitir_doble(f, "    MOV AX, %s\n", c->arg1);
            emitir_doble(f, "    RET\n");
        }

        else /* +, -, *, /, % , relacionales y logicos */
        {
            const char *mnem =
                strcmp(c->op, "+")  == 0 ? "ADD"   :
                strcmp(c->op, "-")  == 0 ? "SUB"   :
                strcmp(c->op, "*")  == 0 ? "MUL"   :
                strcmp(c->op, "/")  == 0 ? "DIV"   :
                strcmp(c->op, "%")  == 0 ? "MOD"   :
                strcmp(c->op, ">")  == 0 ? "CMPGT" :
                strcmp(c->op, "<")  == 0 ? "CMPLT" :
                strcmp(c->op, ">=") == 0 ? "CMPGE" :
                strcmp(c->op, "<=") == 0 ? "CMPLE" :
                strcmp(c->op, "==") == 0 ? "CMPEQ" :
                strcmp(c->op, "!=") == 0 ? "CMPNE" :
                strcmp(c->op, "&&") == 0 ? "AND"   :
                strcmp(c->op, "||") == 0 ? "OR"    : c->op;

            emitir_doble(f, "    MOV AX, %s\n", c->arg1);
            emitir_doble(f, "    %s AX, %s\n", mnem, c->arg2);
            emitir_doble(f, "    MOV %s, AX\n", c->resultado);
        }
    }

    fclose(f);
}

/* =====================================================
   Interprete: recorre el AST y lo ejecuta
   ===================================================== */

/* "retornando" se activa cuando se ejecuta un 'retornar': hace que
   ejecutar() deje de correr el resto de sentencias de la secuencia
   y de las iteraciones de 'mientras' actuales, hasta que la llamada
   que genero el retorno lo recoja y lo vuelva a apagar. */
int retornando = 0;
double valor_retorno = 0;

double evaluar(Nodo *n)
{
    if(!n) return 0;

    switch(n->tipo)
    {
        case N_NUM:
            return n->valor;

        case N_ID:
        {
            int idx = buscar(n->texto);
            if(idx == -1)
            {
                printf("Error en linea %d: '%s' no declarada\n", n->nlinea, n->texto);
                return 0;
            }
            if(tabla_actual()[idx].tipo == 2)
            {
                printf("Error en linea %d: '%s' es cadena, no se puede usar en expresion numerica\n", n->nlinea, n->texto);
                return 0;
            }
            return tabla_actual()[idx].valor;
        }

        case N_BINOP:
        {
            double izq = evaluar(n->a);
            double der = evaluar(n->b);
            switch(n->op)
            {
                case '+': return izq + der;
                case '-': return izq - der;
                case '*': return izq * der;
                case '/':
                    if(der == 0)
                    {
                        printf("Error en linea %d: division por cero\n", n->nlinea);
                        return 0;
                    }
                    return izq / der;
                case '%':
                    if((int)der == 0)
                    {
                        printf("Error en linea %d: modulo por cero\n", n->nlinea);
                        return 0;
                    }
                    return (int)izq % (int)der;
            }
            return 0;
        }

        case N_UMINUS:
            return -evaluar(n->a);

        case N_CALL:
            return llamar_funcion(n);

        default:
            return 0;
    }
}

int evalCond(Nodo *n)
{
    if(!n) return 0;

    switch(n->tipo)
    {
        case N_REL:
        {
            double izq = evaluar(n->a);
            double der = evaluar(n->b);
            switch(n->op)
            {
                case OP_GT: return izq >  der;
                case OP_LT: return izq <  der;
                case OP_GE: return izq >= der;
                case OP_LE: return izq <= der;
                case OP_EQ: return izq == der;
                case OP_NE: return izq != der;
            }
            return 0;
        }
        case N_AND: return evalCond(n->a) && evalCond(n->b);
        case N_OR:  return evalCond(n->a) || evalCond(n->b);
        case N_NOT: return !evalCond(n->a);
        default:    return 0;
    }
}

/* Ejecuta una llamada a funcion (usada tanto para llamadas dentro
   de una expresion como para llamadas-sentencia): evalua los
   argumentos en el ambito de quien llama, apila un marco nuevo con
   los parametros como variables locales, ejecuta el cuerpo y
   devuelve el valor retornado (0 si la funcion es vacio). */
double llamar_funcion(Nodo *n)
{
    FuncInfo *f;
    double valores[MAX_PARAMS];
    int i, idx, retornando_previo;
    double valor_previo, resultado;
    Nodo *p;

    idx = buscar_func(n->texto);
    if(idx == -1)
    {
        printf("Error en linea %d: la funcion '%s' no existe\n", n->nlinea, n->texto);
        return 0;
    }
    f = &tabla_funcs[idx];

    /* Los argumentos se evaluan ANTES de apilar el nuevo marco, en
       el ambito de quien llama (para que "f(x)" use la "x" de
       afuera y no una "x" que pudiera existir dentro de f) */
    i = 0;
    p = n->a;
    while(p && i < MAX_PARAMS)
    {
        valores[i] = evaluar(p->a);
        i++;
        p = p->b;
    }

    if(i != f->num_params)
    {
        printf("Error en linea %d: '%s' espera %d argumento(s) y recibio %d\n",
               n->nlinea, n->texto, f->num_params, i);
        return 0;
    }

    if(tope_pila + 1 >= MAX_PILA)
    {
        printf("Error en linea %d: demasiadas llamadas anidadas (posible recursion infinita)\n", n->nlinea);
        return 0;
    }

    tope_pila++;
    pila_llamadas[tope_pila].num_locales = 0;
    for(i = 0; i < f->num_params; i++)
    {
        int vidx = crear(f->nombres_params[i]);
        tabla_actual()[vidx].tipo  = f->tipos_params[i];
        tabla_actual()[vidx].valor = valores[i];
    }

    /* Guardamos el estado de retorno de quien llama: si f() a su vez
       llama a otra funcion, esta no debe pisar el "retornando" del
       llamador actual */
    retornando_previo = retornando;
    valor_previo       = valor_retorno;
    retornando = 0;

    ejecutar(f->cuerpo);

    resultado = retornando ? valor_retorno : 0;

    tope_pila--;
    retornando    = retornando_previo;
    valor_retorno = valor_previo;

    return resultado;
}

void ejecutar(Nodo *n)
{
    if(!n) return;

    switch(n->tipo)
    {
        case N_SEQ:
            ejecutar(n->a);
            if(retornando) return;
            ejecutar(n->b);
            break;

        case N_DECL_ENTERO:
        {
            int idx = obtener(n->texto);
            if(tabla_actual()[idx].tipo == 1)
                printf("Advertencia en linea %d: '%s' era decimal, ahora es entero\n", n->nlinea, n->texto);
            if(tabla_actual()[idx].tipo == 2)
                printf("Advertencia en linea %d: '%s' era cadena, ahora es entero\n", n->nlinea, n->texto);
            tabla_actual()[idx].tipo  = 0;
            tabla_actual()[idx].valor = n->a ? (int)evaluar(n->a) : 0;
            break;
        }

        case N_DECL_DECIMAL:
        {
            int idx = obtener(n->texto);
            if(tabla_actual()[idx].tipo == 0)
                printf("Advertencia en linea %d: '%s' era entero, ahora es decimal\n", n->nlinea, n->texto);
            if(tabla_actual()[idx].tipo == 2)
                printf("Advertencia en linea %d: '%s' era cadena, ahora es decimal\n", n->nlinea, n->texto);
            tabla_actual()[idx].tipo  = 1;
            tabla_actual()[idx].valor = n->a ? evaluar(n->a) : 0.0;
            break;
        }

        case N_DECL_CADENA:
        {
            int idx = obtener(n->texto);
            if(tabla_actual()[idx].tipo == 0)
                printf("Advertencia en linea %d: '%s' era entero, ahora es cadena\n", n->nlinea, n->texto);
            if(tabla_actual()[idx].tipo == 1)
                printf("Advertencia en linea %d: '%s' era decimal, ahora es cadena\n", n->nlinea, n->texto);
            tabla_actual()[idx].tipo = 2;
            strncpy(tabla_actual()[idx].texto, n->texto2 ? n->texto2 : "", 255);
            break;
        }

        case N_ASSIGN_NUM:
        {
            int idx = buscar(n->texto);
            if(idx == -1)
                printf("Error en linea %d: '%s' no declarada, usa 'entero', 'decimal' o 'cadena'\n", n->nlinea, n->texto);
            else if(tabla_actual()[idx].tipo == 2)
                printf("Error en linea %d: '%s' es cadena, no puedes asignarle un numero\n", n->nlinea, n->texto);
            else
            {
                double v = evaluar(n->a);
                tabla_actual()[idx].valor = (tabla_actual()[idx].tipo == 0) ? (int)v : v;
            }
            break;
        }

        case N_ASSIGN_STR:
        {
            int idx = buscar(n->texto);
            if(idx == -1)
                printf("Error en linea %d: '%s' no declarada, usa 'cadena'\n", n->nlinea, n->texto);
            else if(tabla_actual()[idx].tipo != 2)
                printf("Error en linea %d: '%s' no es cadena\n", n->nlinea, n->texto);
            else
                strncpy(tabla_actual()[idx].texto, n->texto2 ? n->texto2 : "", 255);
            break;
        }

        case N_PRINT_ID:
        {
            int idx = buscar(n->texto);
            if(idx == -1)
                printf("Error en linea %d: '%s' no declarada\n", n->nlinea, n->texto);
            else if(tabla_actual()[idx].tipo == 0)
                printf("Resultado: %d\n", (int)tabla_actual()[idx].valor);
            else if(tabla_actual()[idx].tipo == 1)
                printf("Resultado: %.2lf\n", tabla_actual()[idx].valor);
            else
                printf("%s\n", tabla_actual()[idx].texto);
            break;
        }

        case N_PRINT_EXPR:
        {
            double v = evaluar(n->a);
            if(v == (int)v)
                printf("Resultado: %d\n", (int)v);
            else
                printf("Resultado: %.2lf\n", v);
            break;
        }

        case N_PRINT_STR:
            printf("%s\n", n->texto2 ? n->texto2 : "");
            break;

        case N_IF:
            if(evalCond(n->a))
                ejecutar(n->b);
            else if(n->c)
                ejecutar(n->c);
            break;

        case N_WHILE:
        {
            long iteraciones = 0;
            while(evalCond(n->a))
            {
                ejecutar(n->b);
                if(retornando) break;
                iteraciones++;
                if(iteraciones > 1000000)
                {
                    printf("Advertencia en linea %d: 'mientras' supero 1,000,000 de iteraciones, se detiene por seguridad (revisa la condicion de corte)\n", n->nlinea);
                    break;
                }
            }
            break;
        }

        case N_FUNC_DECL:
            /* Ya se registro en la tabla de funciones durante el
               parseo (ver crear_func_decl); no hay nada que hacer
               al "pasar por" este nodo al ejecutar el programa */
            break;

        case N_RETURN:
            valor_retorno = n->a ? evaluar(n->a) : 0;
            retornando = 1;
            break;

        case N_CALL_STMT:
            llamar_funcion(n);
            break;

        default:
            break;
    }
}

%}

%union {
    int    entero;
    double decimal;
    char  *cadena;
    struct Nodo *nodo;
}

%token <entero>  NUM
%token <decimal> NUMDEC
%token <cadena>  ID
%token <cadena>  LITCADENA

%token ENTERO DECIMAL TCADENA
%token IMPRIMIR
%token SI SINO MIENTRAS
%token GE LE EQ NE AND OR
%token FUNCION RETORNAR VACIO

%type <nodo> expr cond sentencia sentencias bloque
%type <nodo> lista_params parametro lista_args
%type <entero> tipo_retorno

%left OR
%left AND
%right '!'
%nonassoc '>' '<' GE LE EQ NE
%left '+' '-'
%left '*' '/' '%'
%right UMINUS

%%

programa:
        sentencias { raiz = $1; }
        ;

sentencias:
        sentencias sentencia { $$ = crear_seq($1, $2); }
        | /* vacio */         { $$ = NULL; }
        ;

bloque:
        '{' sentencias '}' { $$ = $2; }
        ;

sentencia:

        /* --- Declaracion entero con valor --- */
        ENTERO ID '=' expr ';'
        { $$ = crear_decl(N_DECL_ENTERO, $2, $4); }

        /* --- Declaracion entero sin valor (inicia en 0) --- */
        | ENTERO ID ';'
        { $$ = crear_decl(N_DECL_ENTERO, $2, NULL); }

        /* --- Declaracion decimal con valor --- */
        | DECIMAL ID '=' expr ';'
        { $$ = crear_decl(N_DECL_DECIMAL, $2, $4); }

        /* --- Declaracion decimal sin valor (inicia en 0.0) --- */
        | DECIMAL ID ';'
        { $$ = crear_decl(N_DECL_DECIMAL, $2, NULL); }

        /* --- Declaracion cadena con valor --- */
        | TCADENA ID '=' LITCADENA ';'
        { $$ = crear_decl_str($2, $4); }

        /* --- Declaracion cadena sin valor (inicia vacia) --- */
        | TCADENA ID ';'
        { $$ = crear_decl_str($2, NULL); }

        /* --- Reasignacion sin redeclarar (numeros) --- */
        | ID '=' expr ';'
        { $$ = crear_asig_num($1, $3); }

        /* --- Reasignacion sin redeclarar (cadena) --- */
        | ID '=' LITCADENA ';'
        { $$ = crear_asig_str($1, $3); }

        /* --- imprimir variable --- */
        | IMPRIMIR '(' ID ')' ';'
        { $$ = crear_print_id($3); }

        /* --- imprimir expresion numerica --- */
        | IMPRIMIR '(' expr ')' ';'
        { $$ = crear_print_expr($3); }

        /* --- imprimir literal de cadena --- */
        | IMPRIMIR '(' LITCADENA ')' ';'
        { $$ = crear_print_str($3); }

        /* --- Condicional si/sino (bloques SIEMPRE entre llaves) --- */
        | SI '(' cond ')' bloque SINO bloque
        { $$ = crear_if($3, $5, $7); }

        | SI '(' cond ')' bloque
        { $$ = crear_if($3, $5, NULL); }

        /* --- Bucle mientras --- */
        | MIENTRAS '(' cond ')' bloque
        { $$ = crear_while($3, $5); }

        /* --- Declaracion de funcion --- */
        | FUNCION ID '(' lista_params ')' ':' tipo_retorno bloque
        { $$ = crear_func_decl($2, $7, $4, $8); }

        /* --- Retorno (con o sin valor) --- */
        | RETORNAR expr ';'
        { $$ = crear_return($2); }

        | RETORNAR ';'
        { $$ = crear_return(NULL); }

        /* --- Llamada a funcion como sentencia (se descarta el valor) --- */
        | ID '(' lista_args ')' ';'
        { $$ = crear_call(N_CALL_STMT, $1, $3); }

        ;

lista_params:
        /* vacio */              { $$ = NULL; }
        | parametro              { $$ = $1; }
        | lista_params ',' parametro { $$ = encadenar($1, $3); }
        ;

parametro:
        ENTERO ID  { $$ = crear_param(0, $2); }
        | DECIMAL ID { $$ = crear_param(1, $2); }
        ;

lista_args:
        /* vacio */           { $$ = NULL; }
        | expr                { $$ = crear_arg($1); }
        | lista_args ',' expr { $$ = encadenar($1, crear_arg($3)); }
        ;

tipo_retorno:
        ENTERO   { $$ = 0; }
        | DECIMAL  { $$ = 1; }
        | VACIO    { $$ = -1; }
        ;

cond:
        expr '>' expr  { $$ = crear_rel(OP_GT, $1, $3); }
        | expr '<' expr  { $$ = crear_rel(OP_LT, $1, $3); }
        | expr GE  expr  { $$ = crear_rel(OP_GE, $1, $3); }
        | expr LE  expr  { $$ = crear_rel(OP_LE, $1, $3); }
        | expr EQ  expr  { $$ = crear_rel(OP_EQ, $1, $3); }
        | expr NE  expr  { $$ = crear_rel(OP_NE, $1, $3); }
        | cond AND cond  { $$ = crear_and($1, $3); }
        | cond OR  cond  { $$ = crear_or($1, $3); }
        | '!' cond       { $$ = crear_not($2); }
        | '(' cond ')'   { $$ = $2; }
        ;

expr:

        expr '+' expr  { $$ = crear_binop('+', $1, $3); }

        | expr '-' expr { $$ = crear_binop('-', $1, $3); }

        | expr '*' expr { $$ = crear_binop('*', $1, $3); }

        | expr '/' expr { $$ = crear_binop('/', $1, $3); }

        | expr '%' expr { $$ = crear_binop('%', $1, $3); }

        | '-' expr %prec UMINUS { $$ = crear_uminus($2); }

        | '(' expr ')' { $$ = $2; }

        | NUM     { $$ = crear_num((double)$1); }

        | NUMDEC  { $$ = crear_num($1); }

        | ID      { $$ = crear_idref($1); }

        | ID '(' lista_args ')' { $$ = crear_call(N_CALL, $1, $3); }

        ;

%%

void yyerror(const char *s)
{
    printf("Error sintactico en linea %d: %s\n", linea, s);
}

int main()
{
    int i;
    int resultado;

    setvbuf(stdout, NULL, _IONBF, 0);   /* salida sin buffer: se ve al instante */

    printf("Mini Lenguaje en Espanol\n");
    printf("----------------------------\n");

    resultado = yyparse();

    printf("----------------------------\n");
    if(resultado == 0)
    {
        printf("Programa Correcto\n");
        printf("No existen errores sintacticos\n");
        printf("----------------------------\n");

        /* El sintactico esta OK: se exporta el arbol para Python.
           Si el programa tuviera errores sintacticos, este archivo
           nunca se genera (ver rama 'else' de abajo). */
        exportar_arbol_json(raiz, "arbol.json");

        printf("Arbol Sintactico:\n");
        printf("----------------------------\n");
        imprimir_arbol(raiz, 0);
        printf("----------------------------\n");
        printf("Analizador Semantico\n");
        printf("----------------------------\n");

        /* Fase semantica: recorre el AST completo y valida tipos
           ANTES de ejecutar nada */
        verificar_semantica(raiz);

        /* La tabla de simbolos se exporta siempre que el sintactico
           haya estado bien (haya o no errores semanticos), para que
           se pueda inspeccionar en Python incluso si el programa
           tiene un error de tipos */
        exportar_tabla_json("tabla_simbolos.json");

        if(errores_semanticos > 0)
        {
            printf("----------------------------\n");
            printf("Error semantico\n");
            printf("Se encontraron %d error(es) semantico(s), no se ejecuta el programa\n", errores_semanticos);
            printf("----------------------------\n");
            return 1;
        }

        printf("No existen errores semanticos\n");
        printf("----------------------------\n");
        printf("Tabla de simbolos:\n");
        mostrar_tabla_simbolos();
        printf("----------------------------\n");

        /* Codigo intermedio: solo se genera si el programa paso
           lexico + sintactico + semantico sin errores */
        generar_codigo(raiz);
        exportar_cuadruplos_json("cuadruplos.json");

        printf("Codigo Intermedio (forma lineal):\n");
        printf("----------------------------\n");
        mostrar_codigo_lineal();
        printf("----------------------------\n");
        printf("Codigo Intermedio (cuadruplos):\n");
        printf("----------------------------\n");
        mostrar_cuadruplos();
        printf("----------------------------\n");

        /* Optimizacion de codigo: plegado y propagacion de constantes,
           simplificacion algebraica y eliminacion de codigo muerto,
           aplicadas sobre los cuadruplos generados arriba */
        optimizar_codigo();
        exportar_cuadruplos_opt_json("cuadruplos_opt.json");

        printf("Optimizacion de Codigo:\n");
        printf("----------------------------\n");
        printf("Antes:\n");
        mostrar_codigo_lineal();
        printf("----------------------------\n");
        printf("Despues:\n");
        mostrar_codigo_lineal_opt();
        printf("----------------------------\n");
        printf("Cuadruplos optimizados:\n");
        mostrar_cuadruplos_opt();
        printf("----------------------------\n");
        printf("Resumen de optimizaciones aplicadas:\n");
        printf("  Plegado de constantes:        %d\n", contador_plegado);
        printf("  Propagacion de constantes:    %d\n", contador_propagado);
        printf("  Simplificacion algebraica:    %d\n", contador_simplificado);
        printf("  Eliminacion de codigo muerto: %d\n", contador_muerto);
        printf("----------------------------\n");

        /* Generacion de Codigo Final (punto 16): a partir del codigo
           intermedio ya optimizado, se genera codigo C++ compilable
           y, alternativamente, codigo ensamblador sencillo */
        printf("Generacion de Codigo Final:\n");
        printf("----------------------------\n");
        printf("Codigo C++:\n");
        printf("----------------------------\n");
        generar_codigo_cpp("codigo_final.cpp");
        printf("----------------------------\n");
        printf("Codigo Ensamblador:\n");
        printf("----------------------------\n");
        generar_codigo_asm("codigo_final.asm");
        printf("----------------------------\n");

        /* Solo si paso lexico + sintactico + semantico, se ejecuta */
        ejecutar(raiz);

        printf("----------------------------\n");
        printf("Variables declaradas (valores finales):\n");
        for(i = 0; i < num_vars; i++)
        {
            if(tabla[i].tipo == 0)
                printf("  entero  %s = %d\n",     tabla[i].nombre, (int)tabla[i].valor);
            else if(tabla[i].tipo == 1)
                printf("  decimal %s = %.2lf\n",  tabla[i].nombre, tabla[i].valor);
            else if(tabla[i].tipo == 2)
                printf("  cadena  %s = \"%s\"\n", tabla[i].nombre, tabla[i].texto);
        }
    }
    else
    {
        printf("Programa Incorrecto\n");
        printf("Se encontraron errores sintacticos, no se ejecuta el programa\n");
        printf("(no se genero arbol.json ni tabla_simbolos.json)\n");
    }

    return resultado;
}
