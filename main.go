// otelc-trace-demo: OpenTelemetry 코드가 한 줄도 없는 Gin API.
// `go build`로 빌드하면 평범한 서버, `otelc go build`로 빌드하면 트레이스를 보내는 서버가 된다.
package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
	_ "modernc.org/sqlite"
)

type User struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

type server struct {
	db  *sql.DB
	rdb *redis.Client
}

func main() {
	dbPath := getenv("DB_PATH", filepath.Join(os.TempDir(), "otelc-demo.db"))
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		log.Fatal(err)
	}
	if err := seed(db); err != nil {
		log.Fatal(err)
	}

	rdb := redis.NewClient(&redis.Options{Addr: getenv("REDIS_ADDR", "localhost:6379")})
	s := &server{db: db, rdb: rdb}

	// 요청 로그는 끄고(gin.New) 표준출력은 console 모드의 span 출력용으로 비워 둔다.
	r := gin.New()
	r.Use(gin.Recovery())
	r.GET("/users/:id", s.getUser)            // Redis 캐시 → 없으면 SQLite 조회
	r.GET("/report", s.report)                // 일부러 느린 쿼리
	r.GET("/users-noctx/:id", s.getUserNoCtx) // ctx를 넘기지 않는 코드

	addr := getenv("ADDR", ":8080")
	log.Printf("listening on %s", addr)
	log.Fatal(r.Run(addr))
}

// getUser: 요청 ctx를 Redis·DB 호출까지 넘기는 일반적인 코드.
func (s *server) getUser(c *gin.Context) {
	ctx := c.Request.Context()
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "id must be a number"})
		return
	}
	key := "user:" + strconv.Itoa(id)

	if name, err := s.rdb.Get(ctx, key).Result(); err == nil {
		c.JSON(http.StatusOK, gin.H{"user": User{id, name}, "cache": "hit"})
		return
	}

	var u User
	err = s.db.QueryRowContext(ctx, "SELECT id, name FROM users WHERE id = ?", id).Scan(&u.ID, &u.Name)
	if errors.Is(err, sql.ErrNoRows) {
		c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	s.rdb.Set(ctx, key, u.Name, 30*time.Second)
	c.JSON(http.StatusOK, gin.H{"user": u, "cache": "miss"})
}

// report: 재귀 CTE로 시간을 쓰는 느린 쿼리. 트레이스에서 어느 구간이 느린지 보기 위한 용도.
func (s *server) report(c *gin.Context) {
	var total int64
	err := s.db.QueryRowContext(c.Request.Context(), `
		WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 2000000)
		SELECT sum(x) FROM n`).Scan(&total)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"total": total})
}

// getUserNoCtx: 요청 ctx를 버리고 context.Background()와 ctx 없는 QueryRow를 쓰는 코드.
// 수동 계측이었다면 DB·Redis span이 HTTP span과 끊어진다.
func (s *server) getUserNoCtx(c *gin.Context) {
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "id must be a number"})
		return
	}
	s.rdb.Get(context.Background(), "user:"+strconv.Itoa(id))

	var u User
	if err := s.db.QueryRow("SELECT id, name FROM users WHERE id = ?", id).Scan(&u.ID, &u.Name); err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"user": u})
}

func seed(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)`); err != nil {
		return err
	}
	var n int
	if err := db.QueryRow(`SELECT count(*) FROM users`).Scan(&n); err != nil || n > 0 {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	for i := 1; i <= 100; i++ {
		if _, err := tx.Exec(`INSERT INTO users (id, name) VALUES (?, ?)`, i, "user-"+strconv.Itoa(i)); err != nil {
			tx.Rollback()
			return err
		}
	}
	return tx.Commit()
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
