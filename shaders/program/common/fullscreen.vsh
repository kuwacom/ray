// composite 系パス共通の全画面クアッド
// common を読まない (ftransform / gl_MultiTexCoord0 は組み込みなので include は要らない)

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
