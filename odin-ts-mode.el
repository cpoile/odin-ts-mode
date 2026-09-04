;;; odin-ts-mode.el --- Odin Lang Major Mode for Emacs -*- lexical-binding: t -*-

;; Author: Sampie159
;; URL: https://github.com/Sampie159/odin-ts-mode
;; Keywords: odin languages tree-sitter
;; Version 0.1.0
;; Package-Requires : ((emacs "29.1"))

;;; License:

;; MIT License
;;
;; Copyright (c) 2024 Sampie159
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; Powered by Emacs >= 29 and tree-sitter this major mode provides
;; syntax highlighting, indentation and imenu support for Odin.
;; odin-ts-mode is built against the tree-sitter grammar locatated at
;; https://github.com/tree-sitter-grammars/tree-sitter-odin

;; Much of the structure of this code is based on the c3-ts-mode located at
;; https://github.com/c3lang/c3-ts-mode
;; and on odin-mode located at
;; https://github.com/mattt-b/odin-mode

;; Many thanks for Mickey Petersen for his article "Let's Write a Tree-Sitter Major mode"
;; which can be found at https://www.masteringemacs.org/article/lets-write-a-treesitter-major-mode
;; for helping me do this.

;;; Code:

(require 'treesit)
(require 'c-ts-common)
(require 'cl-lib)
(require 'seq)

;; Dynamically bound by `jit-lock-after-change'.
(defvar jit-lock-start)
(defvar jit-lock-end)

(defgroup odin-ts nil
  "Major mode for editing odin files."
  :prefix "odin-ts-"
  :group 'languages)

(defcustom odin-ts-mode-hook nil
  "Hook run after entering `odin-ts-mode`."
  :version "29.1"
  :type 'symbol
  :group 'odin-ts)

(defcustom odin-ts-mode-indent-offset 4
  "Number of spaces for each indentation step in `odin-ts-mode'."
  :type 'integer
  :safe 'integerp
  :group 'odin-ts)

(defcustom odin-ts-mode-delete-trailing-whitespace nil
  "If non-nil, delete trailing whitespace on save."
  :type 'boolean
  :group 'odin-ts)

(defcustom odin-ts-mode-fontify-inactive-when-blocks t
  "If non-nil, fontify statically inactive `when' branches as comments.
Only conditions made up of boolean literals, parentheses, `!', `&&',
`||', `==', and `!=' are evaluated.  Identifiers, calls, and other
subexpressions are treated as unknown because their values require compiler
context; a branch is changed only when the remaining expression still proves
its condition."
  :type 'boolean
  :group 'odin-ts)

(defconst odin-ts-mode--syntax-table ;; shamelessly stolen directly from odin-mode
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)

    ;; additional symbols
    (modify-syntax-entry ?' "\"" table)
    (modify-syntax-entry ?` "\"" table)
    (modify-syntax-entry ?: "." table)
    (modify-syntax-entry ?+ "." table)
    (modify-syntax-entry ?- "." table)
    (modify-syntax-entry ?% "." table)
    (modify-syntax-entry ?& "." table)
    (modify-syntax-entry ?| "." table)
    (modify-syntax-entry ?^ "." table)
    (modify-syntax-entry ?! "." table)
    (modify-syntax-entry ?$ "." table)
    (modify-syntax-entry ?= "." table)
    (modify-syntax-entry ?< "." table)
    (modify-syntax-entry ?> "." table)
    (modify-syntax-entry ?? "." table)

    ;; Need this for #directive regexes to work correctly
    (modify-syntax-entry ?#   "_" table)

    ;; Modify some syntax entries to allow nested block comments
    (modify-syntax-entry ?/ ". 124b" table)
    (modify-syntax-entry ?* ". 23n" table)
    (modify-syntax-entry ?\n "> b" table)
    (modify-syntax-entry ?\^m "> b" table)

    table)
  "Syntax table for `odin-ts-mode`.")

(defconst odin-ts-mode--includes
  '("import" "package")
  "Includes used in `odin-ts-mode`.")

(defconst odin-ts-mode--storage-classes
  '("distinct" "dynamic")
  "Storage classes used in `odin-ts-mode`.")

(defconst odin-ts-mode--operators
  '(":=" "=" "+" "-" "*" "/" "%" "%%" ">" ">=" "<" "<=" "==" "!=" "~="
    "|" "~" "&" "&~" "<<" ">>" "||" "&&" "!" "^" ".." "+=" "-=" "*="
    "/=" "%=" "&=" "|=" "^=" "<<=" ">>=" "||=" "&&=" "&~=" "..=" "..<" "?")
  "Operators used in `odin-ts-mode`.")

(defconst odin-ts-mode--keywords
  '("foreign"
    "in" "not_in"
    "defer" "return" "proc"
    "struct" "union" "enum" "bit_field" "bit_set" "map"
    "using")
  "Keywords used in the Odin language.")

(defconst odin-ts-mode--special-keywords
  '("or_continue" "or_break" "or_else" "or_return" "do"))

(defconst odin-ts-mode--conditionals
  '("if" "else" "when" "switch" "case" "where" "break")
  "Conditionals used in `odin-ts-mode`.")

(defconst odin-ts-mode--repeats
  '("for" "continue")
  "Repeats used in `odin-ts-mode`.")

(defun odin-ts-mode--semantic-children (node)
  "Return NODE's named children, excluding comments."
  (seq-remove
   (lambda (child)
     (member (treesit-node-type child) '("comment" "block_comment")))
   (treesit-node-children node t)))

(defun odin-ts-mode--constant-boolean-value (node)
  "Return the statically known boolean value of NODE.
The return value is the symbol `true' or `false'.  Return nil when NODE
cannot be evaluated without compiler context."
  (pcase (treesit-node-type node)
    ("boolean"
     (if (string= (treesit-node-text node t) "true") 'true 'false))
    ("parenthesized_expression"
     (when-let* ((child (car (odin-ts-mode--semantic-children node))))
       (odin-ts-mode--constant-boolean-value child)))
    ("unary_expression"
     (when-let* ((operator-node
                  (treesit-node-child-by-field-name node "operator"))
                 (argument-node
                  (treesit-node-child-by-field-name node "argument"))
                 ((string= (treesit-node-text operator-node t) "!")))
       (pcase (odin-ts-mode--constant-boolean-value argument-node)
         ('true 'false)
         ('false 'true))))
    ("binary_expression"
     (when-let* ((operator-node
                  (treesit-node-child-by-field-name node "operator"))
                 (left-node
                  (treesit-node-child-by-field-name node "left"))
                 (right-node
                  (treesit-node-child-by-field-name node "right")))
       (let ((operator (treesit-node-text operator-node t))
             (left (odin-ts-mode--constant-boolean-value left-node))
             (right (odin-ts-mode--constant-boolean-value right-node)))
         (pcase operator
           ("&&"
            (cond ((or (eq left 'false) (eq right 'false)) 'false)
                  ((and (eq left 'true) (eq right 'true)) 'true)))
           ("||"
            (cond ((or (eq left 'true) (eq right 'true)) 'true)
                  ((and (eq left 'false) (eq right 'false)) 'false)))
           ("=="
            (when (and left right)
              (if (eq left right) 'true 'false)))
           ("!="
            (when (and left right)
              (if (eq left right) 'false 'true)))))))))

(defun odin-ts-mode--fontify-when-body (body override start end)
  "Fontify code in BODY as a comment between START and END.
OVERRIDE has the meaning described by `treesit-font-lock-rules'."
  (let ((nodes (if (string= (treesit-node-type body) "block")
                   (treesit-node-children body t)
                 (list body))))
    (dolist (node nodes)
      (let ((node-start (max start (treesit-node-start node)))
            (node-end (min end (treesit-node-end node))))
        (when (< node-start node-end)
          (treesit-fontify-with-override
           node-start node-end 'font-lock-comment-face override))))))

(defun odin-ts-mode--fontify-inactive-when (node override start end &rest _)
  "Fontify statically inactive branches of the `when' statement NODE.
OVERRIDE, START, and END are supplied by tree-sitter font lock."
  (when odin-ts-mode-fontify-inactive-when-blocks
    (let* ((children (odin-ts-mode--semantic-children node))
           (condition (car children))
           (body (cadr children))
           (remaining (cddr children))
           (previous-true nil))
      (cl-labels
          ((fontify-conditional-branch
            (branch-condition branch-body)
            (let ((value
                   (odin-ts-mode--constant-boolean-value branch-condition)))
              (when (or previous-true (eq value 'false))
                (odin-ts-mode--fontify-when-body
                 branch-body override start end))
              (when (eq value 'true)
                (setq previous-true t)))))
        (when (and condition body)
          (fontify-conditional-branch condition body))
        (dolist (clause remaining)
          (pcase (treesit-node-type clause)
            ("else_when_clause"
             (pcase-let ((`(,clause-condition ,clause-body . ,_)
                          (odin-ts-mode--semantic-children clause)))
               (when (and clause-condition clause-body)
                 (fontify-conditional-branch
                  clause-condition clause-body))))
            ("else_clause"
             (when previous-true
               (when-let* ((else-body
                            (car (odin-ts-mode--semantic-children clause))))
                 (odin-ts-mode--fontify-when-body
                  else-body override start end))))))))))

(defun odin-ts-mode--enclosing-when-statement (position)
  "Return the `when_statement' containing POSITION, if any."
  (when (< (point-min) (point-max))
    (let ((node (treesit-node-at
                 (min (max position (point-min)) (1- (point-max)))
                 'odin)))
      (while (and node
                  (not (string= (treesit-node-type node) "when_statement")))
        (setq node (treesit-node-parent node)))
      node)))

(defun odin-ts-mode--extend-font-lock-region-for-when (start end _old-length)
  "Extend fontification around a `when' containing START through END.
This is used by `jit-lock-after-change-extend-region-functions' so changing a
condition immediately updates the face of its branches."
  (when odin-ts-mode-fontify-inactive-when-blocks
    (dolist (position (list start (max start (1- end)) (1- start)))
      (when-let* ((node
                   (odin-ts-mode--enclosing-when-statement position)))
        (setq jit-lock-start
              (min jit-lock-start (treesit-node-start node))
              jit-lock-end
              (max jit-lock-end (treesit-node-end node)))))))

(defvar odin-ts-mode--font-lock-rules
  (treesit-font-lock-rules
   :language 'odin
   :override t
   :feature 'variable
   '((identifier) @font-lock-variable-use-face)

   :language 'odin
   :override t
   :feature 'namespace
   '((package_declaration (identifier) @font-lock-constant-face)
     (import_declaration alias: (identifier) @font-lock-constant-face)
     (foreign_block (identifier) @font-lock-constant-face)
     (using_statement (identifier) @font-lock-constant-face))

   :language 'odin
   :override t
   :feature 'comment
   '([(comment) (block_comment)] @font-lock-comment-face)

   :language 'odin
   :override t
   :feature 'literal
   '((number) @font-lock-number-face
     (float) @font-lock-number-face
     (character) @font-lock-constant-face
     (boolean) @font-lock-constant-face
     [(uninitialized) (nil)] @font-lock-constant-face)

   :language 'odin
   :override t
   :feature 'string
   '((string) @font-lock-string-face)

   :language 'odin
   :override t
   :feature 'escape-sequence
   '((escape_sequence) @font-lock-escape-face)

   :language 'odin
   :override t
   :feature 'preproc
   '([(calling_convention) (tag)] @font-lock-preprocessor-face
     (attribute) @font-lock-preprocessor-face)

   :language 'odin
   :override t
   :feature 'keyword
   `([,@odin-ts-mode--keywords] @font-lock-keyword-face
     [,@odin-ts-mode--includes] @font-lock-keyword-face
     [,@odin-ts-mode--storage-classes] @font-lock-keyword-face
     [,@odin-ts-mode--conditionals (fallthrough_statement)] @font-lock-keyword-face
     [,@odin-ts-mode--repeats] @font-lock-keyword-face)

   :language 'odin
   :override t
   :feature 'special-keyword
   `([,@odin-ts-mode--special-keywords] @font-lock-operator-face)

   :language 'odin
   :override t
   :feature 'builtin
   '(["auto_cast" "cast" "transmute"] @font-lock-builtin-face)

   :language 'odin
   :override t
   :feature 'function
   '((procedure_declaration (identifier) @font-lock-function-name-face)
     (call_expression function: (identifier) @font-lock-function-call-face)
     (overloaded_procedure_declaration (identifier) @font-lock-function-name-face))

   :language 'odin
   :override t
   :feature 'type
   `((struct_declaration (identifier) @font-lock-type-face)
     (type (identifier) @font-lock-type-face)
     (const_declaration (identifier) @font-lock-type-face "::" (bit_set_type))
     (enum_declaration (identifier) @font-lock-type-face)
     (union_declaration (identifier) @font-lock-type-face)
     (bit_field_declaration (identifier) @font-lock-type-face)
     (type (field_type) @font-lock-type-face))

   :language 'odin
   :override t
   :feature 'punctuation
   `([,@odin-ts-mode--operators] @font-lock-punctuation-face
     ["{" "}" "(" ")" "[" "]"] @font-lock-punctuation-face
     ["::" "->" "." "," ":" ";"] @font-lock-punctuation-face
     "$" @font-lock-punctuation-face)

   :language 'odin
   :override t
   :feature 'error
   '((ERROR) @font-lock-warning-face)

   :language 'odin
   :override t
   :feature 'property
   `((field (identifier) @font-lock-property-name-face)
     (struct_field (identifier) @font-lock-property-name-face)
     (member_expression (identifier) (identifier) @font-lock-property-use-face))

   :language 'odin
   :override t
   :feature 'inactive-when
   '((when_statement) @odin-ts-mode--fontify-inactive-when)
   )
  "Font lock rules used by `odin-ts-mode`.")

(defvar odin-ts-mode--font-lock-feature-list
  '((comment string inactive-when)
    (keyword type)
    (builtin preproc escape-sequence literal constant function)
    (operator punctuation variable namespace property special-keyword))
  "Feature list used by `odin-ts-mode`.")

(defun odin-ts-mode--defun-name (node)
  "Return the defun name of NODE.
Return nil if there is no name or if NODE is not a defun node."
  (treesit-node-text
   (treesit-search-subtree node "identifier" nil nil 1)
   t))

(defun odin-ts-mode--type-name (node)
  "Return the name of NODE with type face applied."
  (let ((name (treesit-node-text
               (treesit-search-subtree node "identifier" nil nil 1)
               t)))
    (propertize name 'face 'font-lock-type-face)))

(defun odin-ts-mode--proc-signature (node)
  "Return the full signature for a procedure NODE.
Returns a string like `name (arg1: type) -> return_type`."
  (let* ((name (treesit-node-text
                (treesit-search-subtree node "identifier" nil nil 1)
                t))
         (params (treesit-search-subtree node "parameters"))
         ;; Return type is a sibling of parameters with type "type"
         (returns (when params
                    (let ((sibling (treesit-node-next-sibling params t)))
                      (while (and sibling
                                  (not (string= (treesit-node-type sibling) "type")))
                        (setq sibling (treesit-node-next-sibling sibling t)))
                      sibling))))
    (concat (propertize name 'face 'font-lock-function-name-face)
            (if params
                (concat " :: " (treesit-node-text params t))
              " :: ()")
            (when returns
              (concat " -> " (treesit-node-text returns t))))))

(defconst odin-ts-mode--imenu-settings
  `((nil "\\`struct_declaration\\'" nil odin-ts-mode--type-name)
    (nil "\\`enum_declaration\\'" nil odin-ts-mode--type-name)
    (nil "\\`union_declaration\\'" nil odin-ts-mode--type-name)
    (nil "\\`bit_field_declaration\\'" nil odin-ts-mode--type-name)
    (nil "\\`procedure_declaration\\'" nil odin-ts-mode--proc-signature)
    (nil "\\`overloaded_procedure_declaration\\'" nil odin-ts-mode--proc-signature))
  "Imenu settings used by `odin-ts-mode`.")

;; Adapted from c-ts-mode because the Odin grammar distinguishes line comments
;; from block comments.
(defun odin-ts-comment-2nd-line-matcher (_n parent &rest _)
  "Matches if point is at the second line of a block comment.
PARENT should be a block_comment node."
  (and (equal (treesit-node-type parent) "block_comment")
       (save-excursion
         (forward-line -1)
         (back-to-indentation)
         (eq (point) (treesit-node-start parent)))))

;; Ported from tree-sitter-odin's queries/indents.scm and extended for
;; multiline expressions.
(defvar odin-ts-mode-indent-rules
  '((odin
     ((node-is "]") parent-bol 0)
     ((node-is ")") parent-bol 0)
     ((node-is "}") (and parent parent-bol) 0)

     ((parent-is "^block$") parent-bol odin-ts-mode-indent-offset)

     ;; Declarations
     ((parent-is "enum_declaration") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "union_declaration") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "struct_declaration") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "bit_field_declaration") parent-bol odin-ts-mode-indent-offset)

     ;; Anonymous aggregate types
     ((parent-is "union_type") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "struct_type") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "enum_type") parent-bol odin-ts-mode-indent-offset)

     ((parent-is "^struct$") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "parameters") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "tuple_type") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "call_expression") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "switch_case") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "foreign_block") parent-bol odin-ts-mode-indent-offset)

     ;; Multiline expressions
     ((parent-is "binary_expression") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "unary_expression") parent-bol odin-ts-mode-indent-offset)
     ((parent-is "ternary_expression") parent-bol odin-ts-mode-indent-offset)

     ;; Shamelessely stolen from c-ts-mode
     ((and (parent-is "block_comment") c-ts-common-looking-at-star)
      c-ts-common-comment-start-after-first-star -1)
     (odin-ts-comment-2nd-line-matcher
      c-ts-common-comment-2nd-line-anchor
      1)

     ((parent-is "block_comment") prev-adaptive-prefix 0)

     (catch-all parent-bol 0)))
  "Tree-sitter indent rules for `odin-ts-mode`.")

(defun odin-ts-mode-setup ()
  "Setup treesit for `odin-ts-mode`."

  ;; Highlighting
  (setq-local treesit-font-lock-settings odin-ts-mode--font-lock-rules
              treesit-font-lock-feature-list odin-ts-mode--font-lock-feature-list)

  ;; Indentation
  (setq-local treesit-simple-indent-rules odin-ts-mode-indent-rules
              indent-tabs-mode t
              electric-indent-chars (append "{}():;," electric-indent-chars))

  ;; Imenu
  (setq-local treesit-simple-imenu-settings odin-ts-mode--imenu-settings)

  ;; Defun navigation (enables narrow-to-defun, beginning-of-defun, etc.)
  (setq-local treesit-defun-type-regexp
              (regexp-opt '("procedure_declaration"
                            "overloaded_procedure_declaration"
                            "struct_declaration"
                            "enum_declaration"
                            "union_declaration"
                            "bit_field_declaration")))

  ;; Comment
  (c-ts-common-comment-setup)

  ;; Remove trailing whitespace on save
  (when odin-ts-mode-delete-trailing-whitespace
    (add-hook 'before-save-hook #'delete-trailing-whitespace nil t))

  (treesit-major-mode-setup)
  (add-hook 'jit-lock-after-change-extend-region-functions
            #'odin-ts-mode--extend-font-lock-region-for-when nil t))

;;;###autoload
(define-derived-mode odin-ts-mode prog-mode "odin"
  "Major mode for editing odin files, powered by tree-sitter."
  :group 'odin-ts
  :syntax-table odin-ts-mode--syntax-table

  (when (treesit-ready-p 'odin)
    (treesit-parser-create 'odin)
    (odin-ts-mode-setup)))

(provide 'odin-ts-mode)

;;; odin-ts-mode.el ends here
