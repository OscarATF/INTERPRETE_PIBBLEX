%{
#include "parser.tab.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int linea = 1;
int linea_inicio_comentario = 0;
%}

%option noyywrap

%x COMENTARIO

%%

"/xd"                 {
                          linea_inicio_comentario = linea;
                          BEGIN(COMENTARIO);
                      }

<COMENTARIO>"xd/"     { BEGIN(INITIAL); }

<COMENTARIO>\n        { linea++; }

<COMENTARIO>.         ;                    /* cualquier otro caracter dentro del comentario: ignorar */

<COMENTARIO><<EOF>>   {
                          printf("Error lexico: comentario sin cerrar (iniciado en linea %d, falta 'xd/')\n", linea_inicio_comentario);
                          yyterminate();
                      }

"entero"              { return ENTERO; }
"decimal"             { return DECIMAL; }
"cadena"              { return TCADENA; }
"imprimir"            { return IMPRIMIR; }

"si"                  { return SI; }
"sino"                { return SINO; }
"mientras"            { return MIENTRAS; }

"funcion"             { return FUNCION; }
"retornar"            { return RETORNAR; }
"vacio"               { return VACIO; }

[0-9]+"."[0-9]+       {
                          yylval.decimal = atof(yytext);
                          return NUMDEC;
                      }

[0-9]+                {
                          yylval.entero = atoi(yytext);
                          return NUM;
                      }

[a-zA-Z][a-zA-Z0-9_]* {
                          yylval.cadena = strdup(yytext);
                          return ID;
                      }

">="                  { return GE; }
"<="                  { return LE; }
"=="                  { return EQ; }
"!="                  { return NE; }
"&&"                  { return AND; }
"||"                  { return OR; }

"+"                   { return '+'; }
"-"                   { return '-'; }
"*"                   { return '*'; }
"/"                   { return '/'; }
"%"                   { return '%'; }

">"                   { return '>'; }
"<"                   { return '<'; }
"!"                   { return '!'; }

"="                   { return '='; }
";"                   { return ';'; }
","                   { return ','; }
":"                   { return ':'; }

"("                   { return '('; }
")"                   { return ')'; }
"{"                   { return '{'; }
"}"                   { return '}'; }

\"[^\"]*\"            {
                          yytext[yyleng - 1] = '\0';
                          yylval.cadena = strdup(yytext + 1);
                          return LITCADENA;
                      }

\n                    { linea++; }

[ \t\r]+              ;

.                     {
                          printf("Error lexico en linea %d: %s\n", linea, yytext);
                      }

%%
