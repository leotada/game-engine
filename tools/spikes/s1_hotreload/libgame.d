module libgame;

export extern(C) int game_tick(int counter) {
    return counter * 2 + 1;
}
