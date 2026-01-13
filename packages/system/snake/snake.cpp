#include <iostream>
#include <vector>
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <ctime>
#include <csignal>
#include <cstdlib> // for rand(), srand()

// Minimal Snake Game for GeminiOS
// Uses ANSI escape codes for rendering

bool gameOver;
const int width = 40;
const int height = 20;
int x, y, fruitX, fruitY, score;
int tailX[100], tailY[100];
int nTail;
enum eDirecton { STOP = 0, LEFT, RIGHT, UP, DOWN };
eDirecton dir;

void Setup() {
    gameOver = false;
    dir = STOP;
    x = width / 2;
    y = height / 2;
    fruitX = rand() % width;
    fruitY = rand() % height;
    score = 0;
}

void Draw() {
    std::cout << "\033[H"; // Move cursor to top-left
    for (int i = 0; i < width + 2; i++) std::cout << "#";
    std::cout << std::endl;

    for (int i = 0; i < height; i++) {
        for (int j = 0; j < width; j++) {
            if (j == 0) std::cout << "#";
            if (i == y && j == x)
                std::cout << "O";
            else if (i == fruitY && j == fruitX)
                std::cout << "F";
            else {
                bool print = false;
                for (int k = 0; k < nTail; k++) {
                    if (tailX[k] == j && tailY[k] == i) {
                        std::cout << "o";
                        print = true;
                    }
                }
                if (!print) std::cout << " ";
            }
            if (j == width - 1) std::cout << "#";
        }
        std::cout << std::endl;
    }

    for (int i = 0; i < width + 2; i++) std::cout << "#";
    std::cout << std::endl;
    std::cout << "Score:" << score << std::endl;
    std::cout << "Use WASD to move. X to quit." << std::endl;
}

// Signal handler to exit gracefully
void handle_signal(int signal) {
    if (signal == SIGINT || signal == SIGTERM) {
        gameOver = true;
    }
}

void Input() {
    // Non-blocking read hack for standard C++
    struct timeval tv = { 0L, 0L };
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(0, &fds);
    // Check if input is available
    int ret = select(1, &fds, NULL, NULL, &tv);
    if (ret > 0) {
        char c;
        read(0, &c, 1);
        switch (c) {
            case 'a': dir = LEFT; break;
            case 'd': dir = RIGHT; break;
            case 'w': dir = UP; break;
            case 's': dir = DOWN; break;
            case 'x': gameOver = true; break;
        }
    }
}

void Logic() {
    int prevX = tailX[0];
    int prevY = tailY[0];
    int prev2X, prev2Y;
    tailX[0] = x;
    tailY[0] = y;
    for (int i = 1; i < nTail; i++) {
        prev2X = tailX[i];
        prev2Y = tailY[i];
        tailX[i] = prevX;
        tailY[i] = prevY;
        prevX = prev2X;
        prevY = prev2Y;
    }
    switch (dir) {
        case LEFT: x--; break;
        case RIGHT: x++; break;
        case UP: y--; break;
        case DOWN: y++; break;
        default: break;
    }
    if (x >= width) x = 0; else if (x < 0) x = width - 1;
    if (y >= height) y = 0; else if (y < 0) y = height - 1;

    for (int i = 0; i < nTail; i++)
        if (tailX[i] == x && tailY[i] == y)
            gameOver = true;

    if (x == fruitX && y == fruitY) {
        score += 10;
        fruitX = rand() % width;
        fruitY = rand() % height;
        nTail++;
    }
}

int main() {
    srand(time(0));

    // Register signal handler for Ctrl+C (SIGINT)
    signal(SIGINT, handle_signal);
    
    // Raw mode setup
    struct termios oldt, newt;
    tcgetattr(STDIN_FILENO, &oldt);
    newt = oldt;
    newt.c_lflag &= ~(ICANON | ECHO);
    
    // RAW MODE:
    // Disable ICANON (Line buffering) and ECHO (Printing keys)
    // ENSURE ISIG is ON (Signals like Ctrl+C enabled)
    newt.c_lflag &= ~(ICANON | ECHO); 
    newt.c_lflag |= ISIG; 

    tcsetattr(STDIN_FILENO, TCSANOW, &newt);

    std::cout << "\033[2J"; // Clear screen
    Setup();
    while (!gameOver) {
        Draw();
        Input();
        Logic();
        usleep(100000); // Slow down game loop
    }
    
    // Restore terminal
    tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
    std::cout << "Game Over!" << std::endl;
    return 0;
}
