#lang racket

(require "util.rkt" "ast.rkt")
(provide (all-defined-out))

;; a simple s-expression syntax for datafun.
;; also, "pretty printers", i.e. convert parsed things back to canonical sexps.
;; TODO: an exception class for parse failures.

(define (reserved? x) (set-member? reserved x))
(define reserved
  (list->set '(: = mono <- -> ~>
               empty fn λ cons π proj record record-merge extend-record tag
               quote case if join set let where fix trustme)))

(define (ident? x) (and (symbol? x) (not (reserved? x))))


;;; Expression parsing/pretty-printing
(define (expr->sexp e)
  (match e
    [(or (e-var n _) (e-free-var n)) n]
    [(e-lit v) v]
    [(e-prim p) p]
    [(e-ann t e) `(: ,(type->sexp t) ,(expr->sexp e))]
    [(e-lam v b) `(fn ,v ,(expr->sexp b))]
    [(e-app f a)
     (let loop ([func f] [args (list a)])
       (match func
         [(e-app f a) (loop f (cons a args))]
         [_ (map expr->sexp (cons func args))]))]
    [(e-tuple es) `(cons ,@(map expr->sexp es))]
    [(e-proj i e) `(π ,i ,(expr->sexp e))]
    [(e-record fs) `(record ,@(for/list ([(n e) fs])
                                `(,n ,(expr->sexp e))))]
    [(e-record-merge l r) `(record-merge ,(expr->sexp l) ,(expr->sexp r))]
    [(e-tag t e) `(',t ,(expr->sexp e))]
    [(e-case subj branches)
     `(case ,(expr->sexp subj)
        ,@(for/list ([b branches])
            (match-define (case-branch pat body) b)
            `(,(pat->sexp pat) ,(expr->sexp body))))]
    [(e-join '()) 'empty]
    [(e-join l) `(join ,@(map expr->sexp l))]
    [(e-set es) `(set ,@(map expr->sexp es))]
    [(e-join-in var arg body)
     `(for ([,var ,(expr->sexp arg)]) ,(expr->sexp body))]
    [(e-fix var body) `(fix ,var ,(expr->sexp body))]
    [(e-let tone var expr body)
     `(let ([,@(match tone ['mono '(mono)] ['any '()])
             ,var = ,(expr->sexp expr)])
        ,(expr->sexp body))]
    [(e-trustme e) `(trustme ,(expr->sexp e))]))

;; contexts Γ are simple lists of identifiers - used to map variable names to
;; debruijn indices.
(define (parse-expr e Γ)
  (define (r e) (parse-expr e Γ))
  (match e
    [(? prim?) (e-prim e)]
    [(? lit?) (e-lit e)]
    ['empty (e-join '())]
    [(? ident?)
     (match (index-of e Γ)
       [#f (e-free-var e)]
       [i (e-var e i)])]
    [`(: ,t ,e) (e-ann (parse-type t) (r e))]
    [`(,(or 'fn 'λ) ,xs ... ,e)
     (set! e (parse-expr e (rev-append xs Γ)))
     (foldr e-lam e xs)]
    [`(cons . ,es) (e-tuple (map r es))]
    [`(,(or 'π 'proj) ,i ,e) (e-proj i (r e))]
    [`(record (,ns ,es) ...) (e-record (for/hash ([n ns] [e es])
                                         (values n (r e))))]
    [`(record-merge ,a ,b) (e-record-merge (r a) (r b))]
    [`(extend-record ,base . ,as) (e-record-merge (r base) (r `(record . ,as)))]
    [(or `(tag ,name ,e) `(',name ,e)) (e-tag name (r e))]
    [`(case ,subj (,ps ,es) ...)
      (e-case (r subj)
        (for/list ([p ps] [e es])
          (set! p (parse-pat p))
          (set! e (parse-expr e (rev-append (pat-vars p) Γ)))
          (case-branch p e)))]
    [`(join . ,es) (e-join (map r es))]
    [`(set . ,es) (e-set (map r es))]
    [`(let ,decls ,body)
     (parse-expr-letting (parse-all-decls decls Γ) body Γ)]
    [`(,expr where . ,decls)
     (parse-expr-letting (parse-all-decls decls Γ) expr Γ)]
    [`(for () ,body) (r body)]
    [`(for ([,name ,expr]) ,body)
     (e-join-in name (r expr) (parse-expr body (cons name Γ)))]
    [`(for ([,name ,expr] ,clauses ..1) ,body)
     (r `(for ([,name ,expr]) (for ,clauses ,body)))]
    [`(fix ,x ,body)
      (e-fix x (parse-expr body (cons x Γ)))]
    [`(trustme ,e) (e-trustme (r e))]
    [`(,f ,as ...)
     (if (reserved? f)
         (error "invalid use of form:" e)
         (foldl (flip e-app) (r f) (map r as)))]
    [_ (error "unfamiliar expression:" e)]))


;;; Type parsing/pretty-printing
(define (type->sexp t)
  (define (hash->sexps h)
    (for/list ([(name type) h])
      `(,name ,(type->sexp type))))
  (match t
    [(t-bool) 'bool]
    [(t-nat) 'nat]
    [(t-str) 'str]
    [(t-tuple ts) `(* ,@(map type->sexp ts))]
    [(t-record fields) `(record ,@(hash->sexps fields))]
    [(t-sum branches) `(+ ,@(hash->sexps branches))]
    [(t-fs a) `(set ,(type->sexp a))]
    [(t-fun a b)
     (let loop ([args (list a)] [result b])
       (match result
         [(t-fun a b) (loop (cons a args) b)]
         [_ `(,@(map type->sexp (reverse args)) -> ,(type->sexp result))]))]
    [(t-mono a b)
     (let loop ([args (list a)] [result b])
       (match result
         [(t-mono a b) (loop (cons a args) b)]
         [_ `(,@(map type->sexp (reverse args)) ~> ,(type->sexp result))]))]))

(define (parse-type t)
  (match t
    ['bool (t-bool)]
    ['nat (t-nat)]
    ['str (t-str)]
    [`(* ,as ...) (t-tuple (map parse-type as))]
    [`(record (,ns ,ts) ...)
     (t-record (for/hash ([n ns] [t ts])
                 (values n (parse-type t))))]
    [`(+ (,tags ,types) ...)
      (t-sum (for/hash ([tag tags] [type types])
               (values tag (parse-type type))))]
    [`(,_ ... ,(or '-> '~>) ,_) (parse-arrow-type t)]
    [`(set ,a) (t-fs (parse-type a))]
    [_ (error "unfamiliar type:" t)]))

(define (arrow-type->sexp t)
  (match t
    [(or (t-fun _ _) (t-mono _ _)) (type->sexp t)]
    [_ `(,(type->sexp t))]))

(define (parse-arrow-type t)
  (define (parse t-arr as bs)
    (foldr t-arr (parse-arrow-type bs) (map parse-type as)))
  (match t
    [`(,(and as (not '-> '~>)) ... -> ,bs ..1) (parse t-fun as bs)]
    [`(,(and as (not '-> '~>)) ... ~> ,bs ..1) (parse t-mono as bs)]
    [`(,t) (parse-type t)]))


;; Pattern parsing/pretty-printing
(define (pat->sexp p)
  (match p
    [(p-wild) '_]
    [(p-var x) x]
    [(p-lit x) x]
    [(p-tuple ps) `(cons ,(map pat->sexp ps))]
    [(p-tag name p) `(',name ,(pat->sexp p))]))

(define (parse-pat p)
  (match p
    ['_ (p-wild)]
    [(? ident?) (p-var p)]
    [(? lit?) (p-lit p)]
    [`(cons ,ps ...) (p-tuple (map parse-pat ps))]
    [(or `(tag ,name ,pat) `(',name ,pat))
      (p-tag name (parse-pat pat))]
    [_ (error "unfamiliar pattern:" p)]))


;;; Declaration/definition parsing
;; TODO?: defn->sexp

;; A definition.
;; tone is either 'any or 'mono
;; type is #f if no type signature provided.
(struct defn (name tone type expr) #:transparent)

(struct decl-state (tone-sigs type-sigs) #:transparent)

(define empty-decl-state (decl-state (hash) (hash)))

(define (parse-all-decls ds Γ)
  (define-values (new-state defns) (parse-decls empty-decl-state ds Γ))
  (match-define (decl-state tone-sigs type-sigs) new-state)
  (for ([(n _) type-sigs])
    (error "type ascription for undefined variable:" n))
  (for ([(n _) tone-sigs])
    (error "monotonicity declaration for undefined variable:" n))
  defns)

;; returns (values new-state list-of-defns), or errors
;;
;; for now, we don't support referring to a variable before its definition, not
;; even if you give it a type-signature. also, all recursion must be explicit
;; via `fix'.
(define (parse-decls state ds Γ)
  ;; (printf "parse-decls ~a\n" ds)
  (define defns '())
  (for ([d ds])
    ;; (printf "parsing ~a\n" d)
    (define-values (new-state new-defns) (parse-decl state d Γ))
    (set! state new-state)
    (set! Γ (rev-append (map defn-name new-defns) Γ))
    (set! defns (rev-append new-defns defns)))
  (values state (reverse defns)))

;; returns (values new-state list-of-defns), or errors
(define (parse-decl state d Γ)
  ;; (printf "parse-decl ~a\n" d)
  (match-define (decl-state tone-sigs type-sigs) state)
  (define (ret x) (values (decl-state tone-sigs type-sigs) x))
  (define mono (match (car d)
                 ['mono (set! d (cdr d)) #t]
                 [_ #f]))
  (define (set-mono! n)
    (set! tone-sigs (hash-set tone-sigs n 'mono)))
  (define (set-type! n t)
    (set! type-sigs (hash-set type-sigs n t)))
  (match d
    ;; just a monotonicity declaration
    [`(,(? ident? names) ...) #:when mono
     (for ([n names]) (set-mono! n))
     (ret '())]
    ;; type declaration
    [`(,(? ident? names) ... : ,t ..1)
     (define type (parse-arrow-type t))
     (for ([n names])
       (when mono (set-mono! n))
       (set-type! n type))
     (ret '())]
    ;; a value declaration
    [`(,(? ident? name) ,(? ident? args) ... = . ,body)
     (when mono (set-mono! name))
     (define expr
       `(λ ,@args
          ,(match body
             [`(,expr) expr]
             [`(,expr where . ,decls) body])))
     ;; grab tone & type
     (define tone (hash-ref tone-sigs name 'any))
     (define type (hash-ref type-sigs name #f))
     (set! tone-sigs (hash-remove tone-sigs name))
     (set! type-sigs (hash-remove type-sigs name))
     ;; parse the decl & give it up.
     (ret (list (defn name tone type (parse-expr expr Γ))))]
    [_ (error "could not parse declaration:" d)]))

;; given some defns and an unparsed expr, parses the expr in the appropriate
;; environment and produces an expr which let-binds all the defns in the expr.
(define (parse-expr-letting defns e Γ)
  (set! e (parse-expr e (rev-append (map defn-name defns) Γ)))
  (for/fold ([e e]) ([d (reverse defns)])
    (match-define (defn n k t body) d)
    (e-let k n (if t (e-ann t body) body) e)))