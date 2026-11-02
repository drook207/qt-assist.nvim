#pragma once

#include <QObject>
#include <QString>

namespace app::model {

class Person : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString name READ name WRITE setName NOTIFY nameChanged FINAL)
    QML_ELEMENT

public:
    enum class State { Idle, Busy };
    Q_ENUM(State)

    explicit Person(QObject *parent = nullptr);
    ~Person() override;

    QString name() const;
    void setName(const QString &name);
    State state() const;
    Q_INVOKABLE int compute(int a, int b = 3) const;
    virtual void doIt(std::function<void(int)> cb, const QMap<QString, int> &m = {}) = 0;
    static Person *create();
    inline int inlineFn(int x) const { return x * 2; }

public slots:
    void refresh();

signals:
    void nameChanged();

private:
    QString mName;
    bool mIsValid = false;
    double m_ratio{1.0};
    State mState;
    QList<int> mValues;
    std::function<void(int)> mCallback;
    int count_ : 3;
};

} // namespace app::model
